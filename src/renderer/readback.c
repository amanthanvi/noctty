/* Test-only renderer readback. These are renderer readback pixels, not a DWM capture. */
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <stdint.h>
/* A cross-process HDC can reject GDI drawing. Preserve the exact readback in a
   task-scoped BMP as a transparent fallback; this still bypasses composition. */
int noctty_renderer_save_bgra(const unsigned char *pixels, uint32_t w, uint32_t h, int bottom_up) {
    wchar_t path[32768];
    DWORD len = GetEnvironmentVariableW(L"NOCTTY_RENDERER_CAPTURE_PATH", path, 32768);
    if (!len || len >= 32768) return 0;
    HANDLE file = CreateFileW(path, GENERIC_WRITE, FILE_SHARE_READ, NULL, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
    if (file == INVALID_HANDLE_VALUE) return 0;
    BITMAPFILEHEADER header = {0};
    BITMAPINFOHEADER info = {0};
    DWORD size = w * h * 4;
    header.bfType = 0x4d42;
    header.bfOffBits = sizeof(header) + sizeof(info);
    header.bfSize = header.bfOffBits + size;
    info.biSize = sizeof(info);
    info.biWidth = (LONG)w;
    info.biHeight = bottom_up ? (LONG)h : -(LONG)h;
    info.biPlanes = 1;
    info.biBitCount = 32;
    info.biSizeImage = size;
    DWORD written;
    int ok = WriteFile(file, &header, sizeof(header), &written, NULL) && written == sizeof(header)
        && WriteFile(file, &info, sizeof(info), &written, NULL) && written == sizeof(info)
        && WriteFile(file, pixels, size, &written, NULL) && written == size;
    CloseHandle(file);
    return ok;
}
int noctty_renderer_blit(void *dc, unsigned char *rgba, uint32_t w, uint32_t h, int bottom_up) {
    for (size_t i = 0; i < (size_t)w * h; ++i) {
        unsigned char r = rgba[i * 4];
        rgba[i * 4] = rgba[i * 4 + 2];
        rgba[i * 4 + 2] = r;
        rgba[i * 4 + 3] = 255;
    }
    BITMAPINFO info = {0};
    info.bmiHeader.biSize = sizeof(BITMAPINFOHEADER);
    info.bmiHeader.biWidth = (LONG)w;
    info.bmiHeader.biHeight = bottom_up ? (LONG)h : -(LONG)h;
    info.bmiHeader.biPlanes = 1;
    info.bmiHeader.biBitCount = 32;
    info.bmiHeader.biCompression = BI_RGB;
    int saved = noctty_renderer_save_bgra(rgba, w, h, bottom_up);
    int rows = StretchDIBits((HDC)dc, 0, 0, w, h, 0, 0, w, h, rgba, &info, DIB_RGB_COLORS, SRCCOPY);
    return saved || (rows != 0 && rows != GDI_ERROR);
}
