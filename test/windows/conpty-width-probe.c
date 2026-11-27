// How many columns a console host gives each code point, read from the host's
// own screen buffer (PLAN.md section 7.7, the Unicode 18 width rule), for
// hidden-win11-conpty-width.ps1. No noctty runs: the probe makes the pseudo
// console itself, exactly as noctty's Windows pty does (src/pty.zig: the
// bundled conpty.dll's CreatePseudoConsole with the same flags, or kernel32's
// in-box one), and its client writes each code point and asks the host where
// the cursor went. A cursor-position report cannot do that through the bundled
// pair: it forwards CSI 6n, and noctty answers from its own cursor.
//
//   conpty-width-probe launch <desktop-name> <pair-dir|inbox> <flags-hex> <cps> <out>
//       Makes the private desktop WinSta0\<desktop-name>, runs `probe` on it
//       (lpDesktop by name, in a kill-on-close job), and closes the desktop.
//   conpty-width-probe probe <desktop-name> <pair-dir|inbox> <flags-hex> <cps> <out>
//       Refuses to run on any other desktop. Creates the pseudo console
//       (80x25), answers the host's startup DA1 and drains its output, starts
//       itself as `writer` in it with null std handles and lpDesktop by name,
//       and records which console host served it and on which desktop.
//   conpty-width-probe writer <cps> <out>
//       The pseudo console's client. For each code point, in two output
//       modes (VT processing on, then off): blank row 1, put the cursor at
//       (0, 1), WriteConsoleW the code point alone, and read the host's cursor
//       with GetConsoleScreenBufferInfo and cells 0 and 1 with
//       ReadConsoleOutputW.
//
// <cps> holds one hex code point per line (the first tab-separated column).
// <out> gets, after `key<TAB>value` header lines:
//   cp<TAB>mode<TAB>advance<TAB>cell0_lead_trail<TAB>cell1_lead_trail
// where mode is `vt` or `legacy` and lead_trail is L, T, - or LT for
// COMMON_LVB_LEADING_BYTE and COMMON_LVB_TRAILING_BYTE. It prints no command
// line, path or environment value; it writes only <out> and <out>.host.
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <tlhelp32.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <wchar.h>

#ifndef PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE
#define PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE 0x00020016
#endif
#ifndef ENABLE_VIRTUAL_TERMINAL_PROCESSING
#define ENABLE_VIRTUAL_TERMINAL_PROCESSING 0x0004
#endif
#ifndef DISABLE_NEWLINE_AUTO_RETURN
#define DISABLE_NEWLINE_AUTO_RETURN 0x0008
#endif

typedef void *PCON;
typedef HRESULT(WINAPI *CreateFn)(COORD, HANDLE, HANDLE, DWORD, PCON *);
typedef void(WINAPI *CloseFn)(PCON);

#define MAX_CPS 4096
#define ROW 1

static unsigned cps[MAX_CPS];
static int ncps;

static int load_cps(const wchar_t *path) {
    FILE *f;
    char line[256];
    if (_wfopen_s(&f, path, L"r") || !f) return 0;
    ncps = 0;
    while (fgets(line, sizeof line, f)) {
        char *end;
        unsigned long v = strtoul(line, &end, 16);
        if (end == line) continue;
        if (v > 0x10FFFF || ncps >= MAX_CPS) { fclose(f); return 0; }
        cps[ncps++] = (unsigned)v;
    }
    fclose(f);
    return ncps > 0;
}

static const char *lead_trail(WORD attr) {
    BOOL l = (attr & COMMON_LVB_LEADING_BYTE) != 0, t = (attr & COMMON_LVB_TRAILING_BYTE) != 0;
    return l && t ? "LT" : l ? "L" : t ? "T" : "-";
}

// The name of the desktop this thread is on.
static BOOL own_desktop(wchar_t *name, DWORD cch) {
    DWORD need = 0;
    HDESK d = GetThreadDesktop(GetCurrentThreadId());
    return d && GetUserObjectInformationW(d, UOI_NAME, name, cch * sizeof(wchar_t), &need);
}

static int writer(const wchar_t *cps_path, const wchar_t *out_path) {
    HANDLE out;
    FILE *f;
    CONSOLE_SCREEN_BUFFER_INFO info;
    wchar_t desk[128] = L"";
    static const DWORD modes[2] = {
        ENABLE_PROCESSED_OUTPUT | ENABLE_WRAP_AT_EOL_OUTPUT | ENABLE_VIRTUAL_TERMINAL_PROCESSING | DISABLE_NEWLINE_AUTO_RETURN,
        ENABLE_PROCESSED_OUTPUT | ENABLE_WRAP_AT_EOL_OUTPUT,
    };
    static const char *mode_names[2] = {"vt", "legacy"};
    int m, i;
    if (!load_cps(cps_path)) return 10;
    out = CreateFileW(L"CONOUT$", GENERIC_READ | GENERIC_WRITE, FILE_SHARE_READ | FILE_SHARE_WRITE, NULL, OPEN_EXISTING, 0, NULL);
    if (out == INVALID_HANDLE_VALUE) return 11;
    if (!GetConsoleScreenBufferInfo(out, &info)) return 12;
    if (_wfopen_s(&f, out_path, L"wb") || !f) return 13;
    own_desktop(desk, 128);
    fprintf(f, "writer_desktop_private\t%d\n", desk[0] && _wcsicmp(desk, L"Default") != 0 && _wcsicmp(desk, L"Winlogon") != 0);
    fprintf(f, "writer_console_window\t%d\n", GetConsoleWindow() != NULL);
    fprintf(f, "buffer\t%dx%d\n", info.dwSize.X, info.dwSize.Y);
    for (m = 0; m < 2; ++m) {
        if (!SetConsoleMode(out, modes[m])) { fclose(f); return 14; }
        for (i = 0; i < ncps; ++i) {
            wchar_t units[2];
            DWORD n, done = 0;
            COORD at = {0, ROW};
            CHAR_INFO cells[2];
            COORD size = {2, 1}, origin = {0, 0};
            SMALL_RECT region = {0, ROW, 1, ROW};
            unsigned cp = cps[i];
            if (cp >= 0x10000) {
                units[0] = (wchar_t)(0xD800 + ((cp - 0x10000) >> 10));
                units[1] = (wchar_t)(0xDC00 + ((cp - 0x10000) & 0x3FF));
                n = 2;
            } else {
                units[0] = (wchar_t)cp;
                n = 1;
            }
            if (!FillConsoleOutputCharacterW(out, L' ', (DWORD)info.dwSize.X, at, &done)) { fclose(f); return 15; }
            if (!FillConsoleOutputAttribute(out, info.wAttributes, (DWORD)info.dwSize.X, at, &done)) { fclose(f); return 15; }
            if (!SetConsoleCursorPosition(out, at)) { fclose(f); return 16; }
            if (!WriteConsoleW(out, units, n, &done, NULL) || done != n) { fclose(f); return 17; }
            if (!GetConsoleScreenBufferInfo(out, &info)) { fclose(f); return 18; }
            if (info.dwCursorPosition.Y != ROW) { fclose(f); return 19; }
            if (!ReadConsoleOutputW(out, cells, size, origin, &region)) { fclose(f); return 20; }
            fprintf(f, "%04X\t%s\t%d\t%s\t%s\n", cp, mode_names[m], info.dwCursorPosition.X,
                lead_trail(cells[0].Attributes), lead_trail(cells[1].Attributes));
        }
    }
    fprintf(f, "end\t%d\n", ncps);
    fclose(f);
    CloseHandle(out);
    return 0;
}

typedef struct {
    HANDLE read;
    HANDLE write_in;
    volatile LONG bytes;
    volatile LONG da1_seen;
} Drain;

// Drains the host's output and answers each DA1 query: the bundled
// OpenConsole holds its output until its startup DA1 is answered
// (conpty.md, 2026-10-30).
static DWORD WINAPI drain(void *arg) {
    Drain *d = (Drain *)arg;
    char buf[8192];
    char tail[3] = {0, 0, 0};
    DWORD got;
    while (ReadFile(d->read, buf, sizeof buf, &got, NULL) && got > 0) {
        DWORD i;
        InterlockedExchangeAdd(&d->bytes, (LONG)got);
        for (i = 0; i < got; ++i) {
            tail[0] = tail[1];
            tail[1] = tail[2];
            tail[2] = buf[i];
            if (tail[0] == 0x1b && tail[1] == '[' && tail[2] == 'c') {
                static const char reply[] = "\x1b[?62;22c";
                DWORD w;
                InterlockedIncrement(&d->da1_seen);
                WriteFile(d->write_in, reply, sizeof reply - 1, &w, NULL);
            }
        }
    }
    return 0;
}

typedef struct {
    DWORD pid;
    int count;
} WinCount;

static BOOL CALLBACK count_window(HWND hwnd, LPARAM lp) {
    DWORD pid = 0;
    WinCount *c = (WinCount *)lp;
    GetWindowThreadProcessId(hwnd, &pid);
    if (pid == c->pid) c->count++;
    return TRUE;
}

// The child processes of this probe: its console host (OpenConsole.exe for
// the bundled pair, conhost.exe in-box) and the writer.
static DWORD find_child(const wchar_t *exe) {
    PROCESSENTRY32W e;
    DWORD found = 0;
    HANDLE snap = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
    if (snap == INVALID_HANDLE_VALUE) return 0;
    e.dwSize = sizeof e;
    if (Process32FirstW(snap, &e)) {
        do {
            if (e.th32ParentProcessID == GetCurrentProcessId() && _wcsicmp(e.szExeFile, exe) == 0) found = e.th32ProcessID;
        } while (Process32NextW(snap, &e));
    }
    CloseHandle(snap);
    return found;
}

typedef struct {
    HDESK desk;
    WinCount c;
    BOOL on_desktop;
} MessageOnly;

// Message-only windows are listed only to a thread on their own desktop, so
// a fresh thread (no windows yet, so SetThreadDesktop can move it) counts them.
static DWORD WINAPI count_message_only(void *arg) {
    MessageOnly *m = (MessageOnly *)arg;
    HWND w = NULL;
    if (!SetThreadDesktop(m->desk)) return 1;
    m->on_desktop = TRUE;
    while ((w = FindWindowExW(HWND_MESSAGE, w, NULL, NULL)) != NULL) count_window(w, (LPARAM)&m->c);
    return 0;
}

// The windows (top-level and message-only) that process `pid` has on
// `desktop`, or -1 when the desktop cannot be read.
static int windows_on(const wchar_t *desktop, DWORD pid) {
    WinCount c = {pid, 0};
    MessageOnly m;
    HANDLE t;
    HDESK d = OpenDesktopW(desktop, 0, FALSE, DESKTOP_READOBJECTS | DESKTOP_ENUMERATE);
    if (!d) return -1;
    EnumDesktopWindows(d, count_window, (LPARAM)&c);
    m.desk = d;
    m.c.pid = pid;
    m.c.count = 0;
    m.on_desktop = FALSE;
    t = CreateThread(NULL, 0, count_message_only, &m, 0, NULL);
    if (t) {
        WaitForSingleObject(t, 10000);
        CloseHandle(t);
    }
    CloseDesktop(d);
    return m.on_desktop ? c.count + m.c.count : -1;
}

static int same_file(const wchar_t *a, const wchar_t *b) {
    wchar_t fa[MAX_PATH], fb[MAX_PATH];
    if (!GetFullPathNameW(a, MAX_PATH, fa, NULL) || !GetFullPathNameW(b, MAX_PATH, fb, NULL)) return 0;
    return _wcsicmp(fa, fb) == 0;
}

static int probe(const wchar_t *desk_name, const wchar_t *pair, const wchar_t *flags_hex, const wchar_t *cps_path, const wchar_t *out_path) {
    wchar_t desk[128] = L"", self[MAX_PATH], cmd[3 * MAX_PATH + 64], lp_desktop[160], host_out[MAX_PATH + 8];
    wchar_t dll[MAX_PATH], open_console[MAX_PATH], host_image[MAX_PATH];
    DWORD flags = (DWORD)wcstoul(flags_hex, NULL, 16), host_pid = 0, image_len = MAX_PATH, code = 0, wait;
    BOOL inbox = wcscmp(pair, L"inbox") == 0;
    HMODULE module;
    CreateFn create;
    CloseFn close_pc;
    HANDLE in_read, in_write, out_read, out_write, thread;
    PCON pc = NULL;
    COORD size = {80, 25};
    HRESULT hr;
    Drain d;
    SIZE_T attr_size = 0;
    LPPROC_THREAD_ATTRIBUTE_LIST attrs;
    STARTUPINFOEXW si;
    PROCESS_INFORMATION pi;
    FILE *f;
    int host_private = -1, host_default = -1, console_private = -1, console_default = -1, matched = 0;
    DWORD previous_mode = 0;

    if (!own_desktop(desk, 128) || _wcsicmp(desk, desk_name) != 0) return 30;
    if (_wcsicmp(desk, L"Default") == 0 || _wcsicmp(desk, L"Winlogon") == 0) return 30;
    if (inbox) {
        module = GetModuleHandleW(L"kernel32.dll");
    } else {
        if (swprintf(dll, MAX_PATH, L"%ls\\conpty.dll", pair) < 0) return 31;
        if (swprintf(open_console, MAX_PATH, L"%ls\\OpenConsole.exe", pair) < 0) return 31;
        if (GetFileAttributesW(open_console) == INVALID_FILE_ATTRIBUTES) return 31;
        // noctty's own load (src/pty.zig): no error dialog, the DLL's folder and System32 only.
        SetThreadErrorMode(SEM_FAILCRITICALERRORS | SEM_NOOPENFILEERRORBOX, &previous_mode);
        module = LoadLibraryExW(dll, NULL, LOAD_LIBRARY_SEARCH_DLL_LOAD_DIR | LOAD_LIBRARY_SEARCH_SYSTEM32);
        SetThreadErrorMode(previous_mode, NULL);
    }
    if (!module) return 32;
    create = (CreateFn)(void *)GetProcAddress(module, "CreatePseudoConsole");
    close_pc = (CloseFn)(void *)GetProcAddress(module, "ClosePseudoConsole");
    if (!create || !close_pc) return 33;
    if (!CreatePipe(&in_read, &in_write, NULL, 0) || !CreatePipe(&out_read, &out_write, NULL, 0)) return 34;
    hr = create(size, in_read, out_write, flags, &pc);
    if (FAILED(hr)) return 35;
    CloseHandle(in_read);
    CloseHandle(out_write);
    d.read = out_read;
    d.write_in = in_write;
    d.bytes = 0;
    d.da1_seen = 0;
    {
        static const char reply[] = "\x1b[?62;22c";
        DWORD w;
        WriteFile(in_write, reply, sizeof reply - 1, &w, NULL);
    }
    thread = CreateThread(NULL, 0, drain, &d, 0, NULL);
    if (!thread) return 36;

    host_pid = find_child(inbox ? L"conhost.exe" : L"OpenConsole.exe");
    if (host_pid) {
        HANDLE h = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, host_pid);
        if (h) {
            if (QueryFullProcessImageNameW(h, 0, host_image, &image_len))
                matched = inbox ? 1 : same_file(host_image, open_console);
            CloseHandle(h);
        }
    }

    if (!GetModuleFileNameW(NULL, self, MAX_PATH)) return 37;
    if (swprintf(cmd, sizeof cmd / sizeof cmd[0], L"\"%ls\" writer \"%ls\" \"%ls\"", self, cps_path, out_path) < 0) return 37;
    if (swprintf(lp_desktop, 160, L"WinSta0\\%ls", desk_name) < 0) return 37;
    InitializeProcThreadAttributeList(NULL, 1, 0, &attr_size);
    attrs = (LPPROC_THREAD_ATTRIBUTE_LIST)HeapAlloc(GetProcessHeap(), 0, attr_size);
    if (!attrs || !InitializeProcThreadAttributeList(attrs, 1, 0, &attr_size)) return 38;
    if (!UpdateProcThreadAttribute(attrs, 0, PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE, pc, sizeof pc, NULL, NULL)) return 38;
    ZeroMemory(&si, sizeof si);
    si.StartupInfo.cb = sizeof si;
    // Null std handles, or the client writes past the pseudo console (conpty.md, 2026-09-15).
    si.StartupInfo.dwFlags = STARTF_USESTDHANDLES;
    si.StartupInfo.lpDesktop = lp_desktop;
    si.lpAttributeList = attrs;
    if (!CreateProcessW(NULL, cmd, NULL, NULL, FALSE, EXTENDED_STARTUPINFO_PRESENT, NULL, NULL, &si.StartupInfo, &pi)) return 39;
    CloseHandle(pi.hThread);

    wait = WaitForSingleObject(pi.hProcess, 120000);
    if (wait != WAIT_OBJECT_0) TerminateProcess(pi.hProcess, 99);
    GetExitCodeProcess(pi.hProcess, &code);
    // The host keeps its console window until it is closed, and reports it as
    // owned by its client (conpty.md, 2026-10-25 CLINK-RESIZE-01 trap (3)),
    // so the console window counts under the writer's process number.
    if (host_pid) {
        host_private = windows_on(desk_name, host_pid);
        host_default = windows_on(L"Default", host_pid);
    }
    console_private = windows_on(desk_name, pi.dwProcessId);
    console_default = windows_on(L"Default", pi.dwProcessId);
    {
        CloseHandle(pi.hProcess);
        close_pc(pc);
        CloseHandle(in_write);
        WaitForSingleObject(thread, 10000);
        CloseHandle(thread);
        CloseHandle(out_read);
        DeleteProcThreadAttributeList(attrs);
        HeapFree(GetProcessHeap(), 0, attrs);
        if (swprintf(host_out, MAX_PATH + 8, L"%ls.host", out_path) < 0) return 40;
        if (_wfopen_s(&f, host_out, L"wb") || !f) return 40;
        fprintf(f, "probe_desktop_private\t1\n");
        fprintf(f, "source\t%s\n", inbox ? "inbox" : "bundled");
        fprintf(f, "flags\t0x%lX\n", flags);
        fprintf(f, "host_exe\t%s\n", host_pid ? (inbox ? "conhost.exe" : "OpenConsole.exe") : "none");
        fprintf(f, "host_image_matches\t%d\n", matched);
        fprintf(f, "host_windows_private\t%d\n", host_private);
        fprintf(f, "host_windows_default\t%d\n", host_default);
        fprintf(f, "console_windows_private\t%d\n", console_private);
        fprintf(f, "console_windows_default\t%d\n", console_default);
        fprintf(f, "writer_exit\t%lu\n", code);
        fprintf(f, "writer_timed_out\t%d\n", wait != WAIT_OBJECT_0);
        fprintf(f, "host_output_bytes\t%ld\n", d.bytes);
        fprintf(f, "host_da1_queries\t%ld\n", d.da1_seen);
        fclose(f);
    }
    return code == 0 && host_pid && matched ? 0 : 41;
}

static int launch(const wchar_t *desk_name, const wchar_t *pair, const wchar_t *flags_hex, const wchar_t *cps_path, const wchar_t *out_path) {
    wchar_t self[MAX_PATH], cmd[4 * MAX_PATH + 64], lp_desktop[160];
    HDESK desk;
    HANDLE job;
    JOBOBJECT_EXTENDED_LIMIT_INFORMATION limits;
    STARTUPINFOW si;
    PROCESS_INFORMATION pi;
    DWORD code = 0;
    if (wcsncmp(desk_name, L"noctty-width-", 13) != 0) return 50;
    desk = CreateDesktopW(desk_name, NULL, NULL, 0, GENERIC_ALL, NULL);
    if (!desk) return 51;
    job = CreateJobObjectW(NULL, NULL);
    ZeroMemory(&limits, sizeof limits);
    limits.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE | JOB_OBJECT_LIMIT_DIE_ON_UNHANDLED_EXCEPTION;
    if (!job || !SetInformationJobObject(job, JobObjectExtendedLimitInformation, &limits, sizeof limits)) { CloseDesktop(desk); return 52; }
    if (!GetModuleFileNameW(NULL, self, MAX_PATH)) { CloseDesktop(desk); return 53; }
    if (swprintf(cmd, sizeof cmd / sizeof cmd[0], L"\"%ls\" probe \"%ls\" \"%ls\" %ls \"%ls\" \"%ls\"", self, desk_name, pair, flags_hex, cps_path, out_path) < 0) { CloseDesktop(desk); return 53; }
    if (swprintf(lp_desktop, 160, L"WinSta0\\%ls", desk_name) < 0) { CloseDesktop(desk); return 53; }
    ZeroMemory(&si, sizeof si);
    si.cb = sizeof si;
    si.lpDesktop = lp_desktop;
    // No console of its own (so the only console host among its children is
    // the pseudo console's), suspended until the job holds it.
    if (!CreateProcessW(NULL, cmd, NULL, NULL, FALSE, DETACHED_PROCESS | CREATE_SUSPENDED, NULL, NULL, &si, &pi)) { CloseHandle(job); CloseDesktop(desk); return 54; }
    if (!AssignProcessToJobObject(job, pi.hProcess)) { TerminateProcess(pi.hProcess, 98); CloseHandle(pi.hThread); CloseHandle(pi.hProcess); CloseHandle(job); CloseDesktop(desk); return 55; }
    ResumeThread(pi.hThread);
    CloseHandle(pi.hThread);
    if (WaitForSingleObject(pi.hProcess, 180000) != WAIT_OBJECT_0) TerminateProcess(pi.hProcess, 97);
    GetExitCodeProcess(pi.hProcess, &code);
    CloseHandle(pi.hProcess);
    CloseHandle(job);
    CloseDesktop(desk);
    return (int)code;
}

int wmain(int argc, wchar_t **argv) {
    if (argc == 4 && wcscmp(argv[1], L"writer") == 0) return writer(argv[2], argv[3]);
    if (argc == 7 && wcscmp(argv[1], L"probe") == 0) return probe(argv[2], argv[3], argv[4], argv[5], argv[6]);
    if (argc == 7 && wcscmp(argv[1], L"launch") == 0) return launch(argv[2], argv[3], argv[4], argv[5], argv[6]);
    return 2;
}
