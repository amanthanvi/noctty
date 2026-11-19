// Reply-path reader for hidden-win11-conpty-reply-path.ps1 (the kitty report's
// shortlist #0). Runs as noctty's `-e` child behind ConPTY and records what a
// console client receives when the terminal writes a reply into ConPTY's
// input, in one of four reader states:
//
//   a    console-API reader with ENABLE_VIRTUAL_TERMINAL_INPUT on, line input,
//        echo and processed input off, ReadConsoleInputA 64 records a call
//        (yazi's setup: crossterm raw mode plus VT input)
//   a16  the same input mode, ReadConsoleInputW 16 records a call (the read
//        OpenSSH for Windows before 9.8.2 makes, tncon.c ReadConsoleForTermEmul)
//   b    console-API reader in mode 0x98, no VT input, ReadConsoleInputW 64
//        records a call (the observer of hidden-win11-console-key-records.ps1)
//   c    byte reader with VT input on, line input, echo and processed input
//        off, ReadFile on stdin (the key-input child of pty_transport_probe.zig)
//
//   reader <mode> <log> <ready> <stop>
//
// The harness controls the reader in band, with C0 bytes no reply contains,
// written through noctty's `text:` bindings: 0x01 pushes Kitty keyboard flags
// (CSI > 1 u), 0x0F pops them (CSI < u), 0x04 sends DA1, 0x05 sends
// OSC 11 ; ?, 0x06 sends a kitty graphics query noctty answers OK, 0x0E one
// it answers with an error, 0x10 sends DECRQM for mode 9001 (CSI ? 9001 $ p),
// 0x12 asks for the Kitty flags (CSI ? u), and 0x02 is a case delimiter. A
// command acts on a
// key-down record carrying that unit (a, a16, b) or on that byte (c).
// Mode c also serves the ssh relay (d): the harness starts it on the far side
// of ssh.exe, where it reads bytes behind that session's own pseudo console.
//
// The log has one line per event, timestamps in QueryPerformanceCounter ticks
// (the ready file holds the frequency):
//   READ,<ticks>,<count>             one console read (a, a16, b)
//   KEY,<kd>,<repeat>,<vk>,<scan>,<unit>,<control state>
//   FOCUS,<set> / MOUSE,... / SIZE,<x>,<y> / MENU / OTHER,<type>
//   PEEK,<ticks>,<count>             records queued before a ReadFile (c)
//   SKIP,<ticks>,<count>             c: the peeked records carried no
//                                    character, so they were consumed with
//                                    ReadConsoleInputW (ReadFile would block
//                                    on them); their KEY lines are the PEEK's
//   BYTES,<ticks>,<count>,<hex>      one ReadFile (c)
//   CMD,<ticks>,<code>,<hex>         what the reader wrote for a command
//   STOP,<ticks>                     the stop file seen: a clean stop, the
//                                    log's last line
// The ready file holds
//   pid,inputModeBefore,inputMode,outputMode,inputCodePage,qpcFrequency,localAppDataInRun
// where localAppDataInRun is 1 when %LOCALAPPDATA% lies inside the run
// directory (the log's grandparent), 0 when it does not, 2 when it is unset,
// 3 when it or the run directory cannot be determined.
// Only that answer is written, never the value.
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <stdio.h>
#include <stdlib.h>
#include <share.h>
#include <string.h>

static FILE *g_log;
static HANDLE g_out;

static long long now_ticks(void) {
    LARGE_INTEGER t;
    QueryPerformanceCounter(&t);
    return t.QuadPart;
}

static void write_all(const char *bytes, DWORD len) {
    DWORD offset = 0;
    while (offset < len) {
        DWORD written = 0;
        if (!WriteFile(g_out, bytes + offset, len - offset, &written, NULL) || written == 0) exit(20);
        offset += written;
    }
}

static void log_hex(const unsigned char *bytes, DWORD len) {
    DWORD i;
    for (i = 0; i < len; ++i) fprintf(g_log, "%02x", bytes[i]);
}

// Runs the command a control unit asks for. Returns 1 for a known code.
static int command(unsigned code) {
    static const char push_flags[] = "\x1b[>1u";
    static const char pop_flags[] = "\x1b[<u";
    static const char da1[] = "\x1b[c";
    static const char decrqm_9001[] = "\x1b[?9001$p";
    static const char kitty_flags[] = "\x1b[?u";
    static const char osc11[] = "\x1b]11;?\x1b\\";
    // One RGB pixel, 3 bytes: noctty replies OK.
    static const char kitty_ok[] = "\x1b_Gi=31,s=1,v=1,a=q,t=d,f=24;AAAA\x1b\\";
    // A 2x2 RGB image needs 12 bytes; 3 arrive: noctty replies with an error.
    static const char kitty_error[] = "\x1b_Gi=32,s=2,v=2,a=q,t=d,f=24;AAAA\x1b\\";
    const char *bytes = NULL;
    DWORD len = 0;
    switch (code) {
    case 0x01: bytes = push_flags; len = sizeof(push_flags) - 1; break;
    case 0x0F: bytes = pop_flags; len = sizeof(pop_flags) - 1; break;
    case 0x04: bytes = da1; len = sizeof(da1) - 1; break;
    case 0x10: bytes = decrqm_9001; len = sizeof(decrqm_9001) - 1; break;
    case 0x12: bytes = kitty_flags; len = sizeof(kitty_flags) - 1; break;
    case 0x05: bytes = osc11; len = sizeof(osc11) - 1; break;
    case 0x06: bytes = kitty_ok; len = sizeof(kitty_ok) - 1; break;
    case 0x0E: bytes = kitty_error; len = sizeof(kitty_error) - 1; break;
    case 0x02: fprintf(g_log, "CMD,%lld,02,\n", now_ticks()); return 1;
    default: return 0;
    }
    write_all(bytes, len);
    fprintf(g_log, "CMD,%lld,%02x,", now_ticks(), code);
    log_hex((const unsigned char *)bytes, len);
    fprintf(g_log, "\n");
    return 1;
}

static void log_record(const INPUT_RECORD *r, int ansi) {
    if (r->EventType == KEY_EVENT) {
        const KEY_EVENT_RECORD *key = &r->Event.KeyEvent;
        unsigned unit = ansi ? (unsigned)(unsigned char)key->uChar.AsciiChar : (unsigned)key->uChar.UnicodeChar;
        fprintf(g_log, "KEY,%d,%u,%u,%u,%u,%lu\n", key->bKeyDown ? 1 : 0, (unsigned)key->wRepeatCount,
            (unsigned)key->wVirtualKeyCode, (unsigned)key->wVirtualScanCode, unit, key->dwControlKeyState);
    } else if (r->EventType == MOUSE_EVENT) {
        const MOUSE_EVENT_RECORD *m = &r->Event.MouseEvent;
        fprintf(g_log, "MOUSE,%lu,%d,%d,%lu,%lu\n", m->dwControlKeyState, m->dwMousePosition.X,
            m->dwMousePosition.Y, m->dwButtonState, m->dwEventFlags);
    } else if (r->EventType == FOCUS_EVENT) {
        fprintf(g_log, "FOCUS,%d\n", r->Event.FocusEvent.bSetFocus ? 1 : 0);
    } else if (r->EventType == WINDOW_BUFFER_SIZE_EVENT) {
        fprintf(g_log, "SIZE,%d,%d\n", r->Event.WindowBufferSizeEvent.dwSize.X, r->Event.WindowBufferSizeEvent.dwSize.Y);
    } else if (r->EventType == MENU_EVENT) {
        fprintf(g_log, "MENU\n");
    } else {
        fprintf(g_log, "OTHER,%u\n", (unsigned)r->EventType);
    }
}

// Whether %LOCALAPPDATA% is inside the run: the directory two levels above
// the log (Run\reader-<mode>\reader.log).
// A value can be up to 32767 characters, so the buffers hold any.
static int local_app_data_in_run(const wchar_t *log_path) {
    static wchar_t run[32768], value[32768];
    size_t len;
    int level;
    DWORD got = GetEnvironmentVariableW(L"LOCALAPPDATA", value, 32768);
    if (got == 0) return GetLastError() == ERROR_ENVVAR_NOT_FOUND ? 2 : 3;
    if (got >= 32768) return 3;
    if (wcscpy_s(run, 32768, log_path) != 0) return 3;
    for (level = 0; level < 2; ++level) {
        wchar_t *slash = wcsrchr(run, L'\\');
        if (!slash) return 3;
        *slash = 0;
    }
    len = wcslen(run);
    return _wcsnicmp(value, run, len) == 0 && (value[len] == L'\\' || value[len] == 0) ? 1 : 0;
}

static unsigned record_unit(const INPUT_RECORD *r, int ansi) {
    if (r->EventType != KEY_EVENT || !r->Event.KeyEvent.bKeyDown) return 0;
    return ansi ? (unsigned)(unsigned char)r->Event.KeyEvent.uChar.AsciiChar : (unsigned)r->Event.KeyEvent.uChar.UnicodeChar;
}

int wmain(int argc, wchar_t **argv) {
    HANDLE in = GetStdHandle(STD_INPUT_HANDLE);
    DWORD before = 0, wanted = 0, mode = 0, out_mode = 0;
    LARGE_INTEGER frequency;
    FILE *ready = NULL;
    wchar_t ready_tmp[MAX_PATH];
    ULONGLONG deadline = GetTickCount64() + 15 * 60 * 1000;
    int records = 0, ansi = 0;
    DWORD per_read = 64;
    g_out = GetStdHandle(STD_OUTPUT_HANDLE);
    if (argc != 5) return 2;
    if (!GetConsoleMode(in, &before)) return 3;
    if (wcscmp(argv[1], L"a") == 0) { wanted = (before & ~0x7u) | 0x200; records = 1; ansi = 1; }
    else if (wcscmp(argv[1], L"a16") == 0) { wanted = (before & ~0x7u) | 0x200; records = 1; per_read = 16; }
    else if (wcscmp(argv[1], L"b") == 0) { wanted = 0x98; records = 1; }
    else if (wcscmp(argv[1], L"c") == 0) { wanted = (before & ~0x7u) | 0x200; }
    else return 4;
    if (!SetConsoleMode(in, wanted) || !GetConsoleMode(in, &mode) || mode != wanted) return 5;
    // Queries need VT output, and ConPTY copies raw only with both flags.
    if (!GetConsoleMode(g_out, &out_mode) || !SetConsoleMode(g_out, out_mode | 0x0001 | 0x0004) ||
        !GetConsoleMode(g_out, &out_mode)) return 6;
    g_log = _wfsopen(argv[2], L"wb", _SH_DENYNO);
    if (!g_log) return 7;
    QueryPerformanceFrequency(&frequency);
    // The ready file appears whole: written as <ready>.tmp, closed, then renamed.
    if (swprintf_s(ready_tmp, MAX_PATH, L"%ls.tmp", argv[3]) < 0) return 8;
    if (_wfopen_s(&ready, ready_tmp, L"wb") || !ready) return 8;
    fprintf(ready, "%lu,%lu,%lu,%lu,%u,%lld,%d\n", GetCurrentProcessId(), before, mode, out_mode, GetConsoleCP(),
        frequency.QuadPart, local_app_data_in_run(argv[2]));
    if (fclose(ready) != 0) return 8;
    if (!MoveFileExW(ready_tmp, argv[3], MOVEFILE_REPLACE_EXISTING)) return 13;
    while (GetTickCount64() < deadline && GetFileAttributesW(argv[4]) == INVALID_FILE_ATTRIBUTES) {
        INPUT_RECORD batch[256];
        DWORD count = 0, i;
        if (WaitForSingleObject(in, 50) != WAIT_OBJECT_0) continue;
        if (records) {
            BOOL ok = ansi ? ReadConsoleInputA(in, batch, per_read, &count) : ReadConsoleInputW(in, batch, per_read, &count);
            if (!ok) return 9;
            fprintf(g_log, "READ,%lld,%lu\n", now_ticks(), count);
            // The whole batch is logged before its commands run. The harness posts a case only once it
            // reads the delimiter's CMD line, which follows the batch's records, so a record after a
            // delimiter in the same batch is the closing case's late output, and the log keeps it there.
            for (i = 0; i < count; ++i) log_record(&batch[i], ansi);
            for (i = 0; i < count; ++i) command(record_unit(&batch[i], ansi));
        } else {
            DWORD chars = 0;
            if (!PeekConsoleInputW(in, batch, 256, &count)) return 10;
            fprintf(g_log, "PEEK,%lld,%lu\n", now_ticks(), count);
            for (i = 0; i < count; ++i) {
                log_record(&batch[i], 0);
                if (record_unit(&batch[i], 0) != 0) ++chars;
            }
            if (count > 0 && chars == 0) {
                if (!ReadConsoleInputW(in, batch, count, &count)) return 11;
                fprintf(g_log, "SKIP,%lld,%lu\n", now_ticks(), count);
            } else if (count > 0) {
                unsigned char bytes[4096];
                DWORD got = 0;
                if (!ReadFile(in, bytes, sizeof(bytes), &got, NULL)) return 12;
                fprintf(g_log, "BYTES,%lld,%lu,", now_ticks(), got);
                log_hex(bytes, got);
                fprintf(g_log, "\n");
                for (i = 0; i < got; ++i) command(bytes[i]);
            }
        }
        fflush(g_log);
    }
    if (GetFileAttributesW(argv[4]) != INVALID_FILE_ATTRIBUTES) fprintf(g_log, "STOP,%lld\n", now_ticks());
    fclose(g_log);
    return 0;
}
