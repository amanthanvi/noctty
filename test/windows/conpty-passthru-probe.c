// Which bytes a console host passes on to the terminal when its client writes
// an escape sequence, read from the host's own output pipe (what noctty
// reads), for hidden-win11-conpty-passthru.ps1: the mode resets the shell
// integrations send at the prompt (conpty.md, 2026-11-27 CONPTY-PASSTHRU-01).
// No noctty runs: the probe makes the pseudo console itself, exactly as
// noctty's Windows pty does (src/pty.zig: the bundled conpty.dll's
// CreatePseudoConsole with the same flags, or kernel32's in-box one). It is
// conpty-width-probe.c with another client: the same private desktop, job,
// load, DA1 answer and null std handles.
//
//   conpty-passthru-probe launch <desktop-name> <pair-dir|inbox> <flags-hex> <cases> <out>
//       Makes the private desktop WinSta0\<desktop-name> (the name starts
//       noctty-passthru-), runs `probe` on it (lpDesktop by name, in a
//       kill-on-close job), and closes the desktop.
//   conpty-passthru-probe probe <desktop-name> <pair-dir|inbox> <flags-hex> <cases> <out>
//       Refuses to run on any other desktop. Creates the pseudo console
//       (80x25), answers the host's startup DA1, keeps every byte the host
//       writes in <out>.raw, starts itself as `writer` in it with null std
//       handles and lpDesktop by name, and records which console host served
//       it and on which desktop.
//   conpty-passthru-probe writer <cases> <out>
//       The pseudo console's client. Turns VT processing on and writes each
//       case as `<Pn>`, its bytes and `</Pn>` CR LF in one WriteFile (the
//       byte path, which PowerShell's [Console]::Write is inferred to take;
//       cmd and Clink are inferred to use WriteConsoleW, not measured here),
//       300 ms apart.
//
// <cases> holds one case per line: its bytes in hex, two digits a byte, at
// most 512 bytes, or `-` for a case with no bytes. <out> gets the writer's
// `key<TAB>value` lines, <out>.host the probe's, and <out>.raw the host's
// output, DA1 queries and window title included. It prints no command line,
// path or environment value; it writes only those three files.
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

#define MAX_CASES 64
#define MAX_CASE_BYTES 512

static unsigned char case_bytes[MAX_CASES][MAX_CASE_BYTES];
static size_t case_len[MAX_CASES];
static int ncases;

static int hex_digit(char c) {
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    if (c >= 'A' && c <= 'F') return c - 'A' + 10;
    return -1;
}

static int load_cases(const wchar_t *path) {
    FILE *f;
    char line[2 * MAX_CASE_BYTES + 8];
    if (_wfopen_s(&f, path, L"rb") || !f) return 0;
    ncases = 0;
    while (fgets(line, sizeof line, f)) {
        size_t n = strlen(line), i;
        // A line longer than the buffer would come back in pieces.
        if ((n == 0 || line[n - 1] != '\n') && !feof(f)) { fclose(f); return 0; }
        while (n > 0 && (line[n - 1] == '\n' || line[n - 1] == '\r')) line[--n] = 0;
        if (n == 0) continue;
        if (ncases >= MAX_CASES) { fclose(f); return 0; }
        if (n == 1 && line[0] == '-') { case_len[ncases++] = 0; continue; }
        if (n % 2 != 0 || n / 2 > MAX_CASE_BYTES) { fclose(f); return 0; }
        for (i = 0; i < n; i += 2) {
            int hi = hex_digit(line[i]), lo = hex_digit(line[i + 1]);
            if (hi < 0 || lo < 0) { fclose(f); return 0; }
            case_bytes[ncases][i / 2] = (unsigned char)(hi * 16 + lo);
        }
        case_len[ncases++] = n / 2;
    }
    fclose(f);
    return ncases > 0;
}

// The name of the desktop this thread is on.
static BOOL own_desktop(wchar_t *name, DWORD cch) {
    DWORD need = 0;
    HDESK d = GetThreadDesktop(GetCurrentThreadId());
    return d && GetUserObjectInformationW(d, UOI_NAME, name, cch * sizeof(wchar_t), &need);
}

static int writer(const wchar_t *cases_path, const wchar_t *out_path) {
    HANDLE out;
    FILE *f;
    wchar_t desk[128] = L"";
    char buf[MAX_CASE_BYTES + 64];
    DWORD done;
    int i;
    if (!load_cases(cases_path)) return 10;
    out = CreateFileW(L"CONOUT$", GENERIC_READ | GENERIC_WRITE, FILE_SHARE_READ | FILE_SHARE_WRITE, NULL, OPEN_EXISTING, 0, NULL);
    if (out == INVALID_HANDLE_VALUE) return 11;
    if (!SetConsoleMode(out, ENABLE_PROCESSED_OUTPUT | ENABLE_WRAP_AT_EOL_OUTPUT | ENABLE_VIRTUAL_TERMINAL_PROCESSING | DISABLE_NEWLINE_AUTO_RETURN)) return 14;
    // Past the host's startup output before the first case.
    Sleep(500);
    for (i = 0; i < ncases; ++i) {
        int head, tail;
        size_t n;
        head = sprintf_s(buf, sizeof buf, "<P%d>", i);
        if (head <= 0) return 15;
        memcpy(buf + head, case_bytes[i], case_len[i]);
        n = (size_t)head + case_len[i];
        tail = sprintf_s(buf + n, sizeof buf - n, "</P%d>\r\n", i);
        if (tail <= 0) return 15;
        n += (size_t)tail;
        if (!WriteFile(out, buf, (DWORD)n, &done, NULL) || done != (DWORD)n) return 17;
        Sleep(300);
    }
    // Long enough for the host to write the last case out before its client goes.
    Sleep(1500);
    if (_wfopen_s(&f, out_path, L"wb") || !f) return 13;
    own_desktop(desk, 128);
    fprintf(f, "writer_desktop_private\t%d\n", desk[0] && _wcsicmp(desk, L"Default") != 0 && _wcsicmp(desk, L"Winlogon") != 0);
    fprintf(f, "writer_console_window\t%d\n", GetConsoleWindow() != NULL);
    fprintf(f, "cases\t%d\n", ncases);
    fclose(f);
    CloseHandle(out);
    return 0;
}

typedef struct {
    HANDLE read;
    HANDLE write_in;
    FILE *raw;
    volatile LONG bytes;
    volatile LONG da1_seen;
    volatile LONG raw_failed;
} Drain;

// Drains the host's output into <out>.raw and answers each DA1 query: the
// bundled OpenConsole holds its output until its startup DA1 is answered
// (conpty.md, 2026-10-30).
static DWORD WINAPI drain(void *arg) {
    Drain *d = (Drain *)arg;
    char buf[8192];
    char tail[3] = {0, 0, 0};
    DWORD got;
    while (ReadFile(d->read, buf, sizeof buf, &got, NULL) && got > 0) {
        DWORD i;
        InterlockedExchangeAdd(&d->bytes, (LONG)got);
        if (fwrite(buf, 1, got, d->raw) != got || fflush(d->raw) != 0) InterlockedExchange(&d->raw_failed, 1);
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

static int probe(const wchar_t *desk_name, const wchar_t *pair, const wchar_t *flags_hex, const wchar_t *cases_path, const wchar_t *out_path) {
    wchar_t desk[128] = L"", self[MAX_PATH], cmd[3 * MAX_PATH + 64], lp_desktop[160], host_out[MAX_PATH + 8], raw_out[MAX_PATH + 8];
    wchar_t dll[MAX_PATH], open_console[MAX_PATH], host_image[MAX_PATH];
    DWORD flags = (DWORD)wcstoul(flags_hex, NULL, 16), host_pid = 0, image_len = MAX_PATH, code = 0, wait, drained;
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
    if (swprintf(raw_out, MAX_PATH + 8, L"%ls.raw", out_path) < 0) return 34;
    d.raw = NULL;
    if (_wfopen_s(&d.raw, raw_out, L"wb") || !d.raw) return 34;
    if (!CreatePipe(&in_read, &in_write, NULL, 0) || !CreatePipe(&out_read, &out_write, NULL, 0)) return 34;
    hr = create(size, in_read, out_write, flags, &pc);
    if (FAILED(hr)) return 35;
    CloseHandle(in_read);
    CloseHandle(out_write);
    d.read = out_read;
    d.write_in = in_write;
    d.bytes = 0;
    d.da1_seen = 0;
    d.raw_failed = 0;
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
    if (swprintf(cmd, sizeof cmd / sizeof cmd[0], L"\"%ls\" writer \"%ls\" \"%ls\"", self, cases_path, out_path) < 0) return 37;
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
        // Closing the pseudo console ends the host, which ends the drain;
        // <out>.raw is closed only once the drain is done with it.
        drained = WaitForSingleObject(thread, 10000);
        CloseHandle(thread);
        if (drained == WAIT_OBJECT_0) {
            CloseHandle(out_read);
            if (fclose(d.raw) != 0) d.raw_failed = 1;
        }
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
        fprintf(f, "drain_finished\t%d\n", drained == WAIT_OBJECT_0);
        fprintf(f, "raw_write_failed\t%ld\n", d.raw_failed);
        fprintf(f, "host_output_bytes\t%ld\n", d.bytes);
        fprintf(f, "host_da1_queries\t%ld\n", d.da1_seen);
        fclose(f);
    }
    return code == 0 && host_pid && matched && drained == WAIT_OBJECT_0 && !d.raw_failed ? 0 : 41;
}

static int launch(const wchar_t *desk_name, const wchar_t *pair, const wchar_t *flags_hex, const wchar_t *cases_path, const wchar_t *out_path) {
    wchar_t self[MAX_PATH], cmd[4 * MAX_PATH + 64], lp_desktop[160];
    HDESK desk;
    HANDLE job;
    JOBOBJECT_EXTENDED_LIMIT_INFORMATION limits;
    STARTUPINFOW si;
    PROCESS_INFORMATION pi;
    DWORD code = 0;
    if (wcsncmp(desk_name, L"noctty-passthru-", 16) != 0) return 50;
    desk = CreateDesktopW(desk_name, NULL, NULL, 0, GENERIC_ALL, NULL);
    if (!desk) return 51;
    job = CreateJobObjectW(NULL, NULL);
    ZeroMemory(&limits, sizeof limits);
    limits.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE | JOB_OBJECT_LIMIT_DIE_ON_UNHANDLED_EXCEPTION;
    if (!job || !SetInformationJobObject(job, JobObjectExtendedLimitInformation, &limits, sizeof limits)) { CloseDesktop(desk); return 52; }
    if (!GetModuleFileNameW(NULL, self, MAX_PATH)) { CloseDesktop(desk); return 53; }
    if (swprintf(cmd, sizeof cmd / sizeof cmd[0], L"\"%ls\" probe \"%ls\" \"%ls\" %ls \"%ls\" \"%ls\"", self, desk_name, pair, flags_hex, cases_path, out_path) < 0) { CloseDesktop(desk); return 53; }
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
