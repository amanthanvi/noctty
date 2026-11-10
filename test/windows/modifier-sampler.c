// Samples whether Shift, Ctrl, Alt or Win is down at the real keyboard, for
// hidden-win11-tab-tearoff.ps1. That harness drives noctty on a private
// desktop, where GetAsyncKeyState reads 0 (it reads the keyboard only from
// the active desktop), while a modifier held at the real keyboard can still
// reach a private desktop's windows (input.md, 2026-10-11, trap 11). Started
// on WinSta0\Default with no window (CREATE_NO_WINDOW); every 10 ms until the
// file argv[2] exists, and writes to argv[1] a line for each sample in which
// a modifier was down or this desktop was not the input desktop:
//   <GetTickCount64>,<held 0|1>,<active 0|1>
// then a last line
//   done,<samples>
// No other key is read.
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <stdio.h>
#include <wchar.h>

#pragma comment(lib, "user32.lib")

static int input_desktop_is_default(void) {
    wchar_t name[64];
    DWORD length = 0;
    int is_default = 0;
    HDESK input = OpenInputDesktop(0, FALSE, DESKTOP_READOBJECTS);
    if (!input) return 0;
    if (GetUserObjectInformationW(input, UOI_NAME, name, sizeof(name), &length)) {
        is_default = _wcsicmp(name, L"Default") == 0;
    }
    CloseDesktop(input);
    return is_default;
}

int wmain(int argc, wchar_t **argv) {
    static const int keys[] = { VK_SHIFT, VK_CONTROL, VK_MENU, VK_LWIN, VK_RWIN };
    FILE *out;
    unsigned long long samples = 0;
    if (argc != 3) return 2;
    if (_wfopen_s(&out, argv[1], L"w") || !out) return 3;
    while (GetFileAttributesW(argv[2]) == INVALID_FILE_ATTRIBUTES) {
        int held = 0, active = input_desktop_is_default();
        size_t i;
        for (i = 0; i < sizeof(keys) / sizeof(keys[0]); ++i) {
            if (GetAsyncKeyState(keys[i]) & 0x8000) held = 1;
        }
        ++samples;
        if (held || !active) {
            fprintf(out, "%llu,%d,%d\n", GetTickCount64(), held, active);
            fflush(out);
        }
        Sleep(10);
    }
    fprintf(out, "done,%llu\n", samples);
    fclose(out);
    return 0;
}
