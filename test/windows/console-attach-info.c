// Attach to another process's console and report its input mode and screen
// buffer geometry, for hidden-win11-herdr-mouse.ps1 and the PSReadLine phase
// of hidden-win11-console-key-records.ps1. Started with no console of its own
// (CREATE_NO_WINDOW); writes to the file in argv[2] one line
//   inputMode,bufferWidth,bufferHeight,windowLeft,windowTop,windowRight,windowBottom,outputMode
// followed, when argv[3] is "dump", by the text of every row in the window;
// "window-dump" writes the console's window handle (GetConsoleWindow, in
// decimal) on a line of its own before the rows, for
// hidden-win11-tab-tearoff.ps1, which asks which window owns it.
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

int wmain(int argc, wchar_t **argv) {
    DWORD pid, input_mode = 0, output_mode = 0;
    HANDLE in, out;
    CONSOLE_SCREEN_BUFFER_INFO info = {0};
    FILE *result;
    BOOL dump, window;
    if (argc != 3 && argc != 4) return 2;
    window = argc == 4 && wcscmp(argv[3], L"window-dump") == 0;
    dump = window || (argc == 4 && wcscmp(argv[3], L"dump") == 0);
    pid = (DWORD)wcstoul(argv[1], NULL, 10);
    FreeConsole();
    if (!AttachConsole(pid)) return 3;
    in = CreateFileW(L"CONIN$", GENERIC_READ | GENERIC_WRITE, FILE_SHARE_READ | FILE_SHARE_WRITE, NULL, OPEN_EXISTING, 0, NULL);
    out = CreateFileW(L"CONOUT$", GENERIC_READ | GENERIC_WRITE, FILE_SHARE_READ | FILE_SHARE_WRITE, NULL, OPEN_EXISTING, 0, NULL);
    if (in == INVALID_HANDLE_VALUE || out == INVALID_HANDLE_VALUE) return 4;
    if (!GetConsoleMode(in, &input_mode)) return 5;
    GetConsoleMode(out, &output_mode);
    if (!GetConsoleScreenBufferInfo(out, &info)) return 6;
    if (_wfopen_s(&result, argv[2], L"w, ccs=UTF-8") || !result) return 7;
    fwprintf(result, L"%lu,%d,%d,%d,%d,%d,%d,%lu\n", input_mode, info.dwSize.X, info.dwSize.Y,
        info.srWindow.Left, info.srWindow.Top, info.srWindow.Right, info.srWindow.Bottom, output_mode);
    if (window) fwprintf(result, L"%llu\n", (unsigned long long)(ULONG_PTR)GetConsoleWindow());
    if (dump) {
        SHORT y;
        for (y = info.srWindow.Top; y <= info.srWindow.Bottom; ++y) {
            wchar_t row[1024];
            DWORD read = 0, width = (DWORD)(info.srWindow.Right - info.srWindow.Left + 1);
            COORD at = { info.srWindow.Left, y };
            if (width > 1023) width = 1023;
            if (!ReadConsoleOutputCharacterW(out, row, width, at, &read)) break;
            row[read] = 0;
            while (read > 0 && row[read - 1] == L' ') row[--read] = 0;
            fwprintf(result, L"%ls\n", row);
        }
    }
    fclose(result);
    CloseHandle(in);
    CloseHandle(out);
    FreeConsole();
    return 0;
}
