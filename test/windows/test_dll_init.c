/*
 * Packaged ghostty-vt.dll smoke. The portable ZIP carries a placeholder under
 * that name (src/ghostty_vt_stub/), not libghostty-vt, and this checks that
 * the file a package carries is the placeholder:
 *   1. LoadLibraryExW fails with ERROR_DLL_INIT_FAILED (its DllMain refuses
 *      DLL_PROCESS_ATTACH);
 *   2. its export table is empty (read from the file, never run);
 *   3. its version resource's FileDescription is the one passed in.
 * Usage: test_dll_init.exe <absolute ghostty-vt.dll path> <FileDescription>
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <windows.h>
#include <shellapi.h>

static int check_load_fails(const wchar_t *path) {
  HMODULE dll = LoadLibraryExW(
      path, NULL,
      LOAD_LIBRARY_SEARCH_DLL_LOAD_DIR | LOAD_LIBRARY_SEARCH_DEFAULT_DIRS);
  DWORD error = GetLastError();
  if (dll) {
    fprintf(stderr, "LoadLibraryExW loaded the DLL; the placeholder must fail to initialise\n");
    FreeLibrary(dll);
    return 0;
  }
  if (error != ERROR_DLL_INIT_FAILED) {
    fprintf(stderr, "LoadLibraryExW failed with %lu, not ERROR_DLL_INIT_FAILED (%lu)\n",
            error, (DWORD)ERROR_DLL_INIT_FAILED);
    return 0;
  }
  return 1;
}

/* Reads the PE headers from the file itself, so nothing in it runs. */
static int check_no_exports(const wchar_t *path) {
  HANDLE file = CreateFileW(path, GENERIC_READ, FILE_SHARE_READ, NULL,
                            OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, NULL);
  if (file == INVALID_HANDLE_VALUE) {
    fprintf(stderr, "CreateFileW failed: %lu\n", GetLastError());
    return 0;
  }
  unsigned char headers[4096];
  DWORD read = 0;
  BOOL ok = ReadFile(file, headers, sizeof(headers), &read, NULL);
  CloseHandle(file);
  if (!ok || read < sizeof(IMAGE_DOS_HEADER)) {
    fprintf(stderr, "Could not read the PE headers\n");
    return 0;
  }
  const IMAGE_DOS_HEADER *dos = (const IMAGE_DOS_HEADER *)headers;
  if (dos->e_magic != IMAGE_DOS_SIGNATURE || dos->e_lfanew < 0 ||
      (DWORD)dos->e_lfanew + sizeof(IMAGE_NT_HEADERS64) > read) {
    fprintf(stderr, "Not a PE image, or its headers are past the first 4 KB\n");
    return 0;
  }
  const unsigned char *nt = headers + dos->e_lfanew;
  if (*(const DWORD *)nt != IMAGE_NT_SIGNATURE) {
    fprintf(stderr, "No PE signature\n");
    return 0;
  }
  const IMAGE_FILE_HEADER *coff = (const IMAGE_FILE_HEADER *)(nt + 4);
  const unsigned char *optional = nt + 4 + sizeof(IMAGE_FILE_HEADER);
  WORD magic = *(const WORD *)optional;
  DWORD count;
  const IMAGE_DATA_DIRECTORY *dirs;
  if (magic == IMAGE_NT_OPTIONAL_HDR64_MAGIC) {
    const IMAGE_OPTIONAL_HEADER64 *h = (const IMAGE_OPTIONAL_HEADER64 *)optional;
    count = h->NumberOfRvaAndSizes;
    dirs = h->DataDirectory;
  } else if (magic == IMAGE_NT_OPTIONAL_HDR32_MAGIC) {
    const IMAGE_OPTIONAL_HEADER32 *h = (const IMAGE_OPTIONAL_HEADER32 *)optional;
    count = h->NumberOfRvaAndSizes;
    dirs = h->DataDirectory;
  } else {
    fprintf(stderr, "Unknown optional header magic 0x%x\n", magic);
    return 0;
  }
  if ((const unsigned char *)(dirs + IMAGE_DIRECTORY_ENTRY_EXPORT + 1) > headers + read ||
      (const unsigned char *)(dirs + IMAGE_DIRECTORY_ENTRY_EXPORT + 1) >
          optional + coff->SizeOfOptionalHeader) {
    fprintf(stderr, "Truncated data directory table\n");
    return 0;
  }
  if (count > IMAGE_DIRECTORY_ENTRY_EXPORT &&
      (dirs[IMAGE_DIRECTORY_ENTRY_EXPORT].VirtualAddress != 0 ||
       dirs[IMAGE_DIRECTORY_ENTRY_EXPORT].Size != 0)) {
    fprintf(stderr, "The DLL has an export table (%lu bytes); the placeholder exports nothing\n",
            dirs[IMAGE_DIRECTORY_ENTRY_EXPORT].Size);
    return 0;
  }
  return 1;
}

static int check_description(const wchar_t *path, const wchar_t *expected) {
  DWORD ignored = 0;
  DWORD size = GetFileVersionInfoSizeW(path, &ignored);
  if (size == 0) {
    fprintf(stderr, "No version resource: %lu\n", GetLastError());
    return 0;
  }
  void *info = malloc(size);
  if (!info) return 0;
  int result = 0;
  wchar_t *description = NULL;
  UINT length = 0;
  if (!GetFileVersionInfoW(path, 0, size, info)) {
    fprintf(stderr, "GetFileVersionInfoW failed: %lu\n", GetLastError());
  } else if (!VerQueryValueW(info, L"\\StringFileInfo\\040904b0\\FileDescription",
                             (void **)&description, &length) ||
             !description) {
    fprintf(stderr, "The version resource has no FileDescription\n");
  } else if (wcscmp(description, expected) != 0) {
    fprintf(stderr, "FileDescription '%ls' is not the placeholder's\n", description);
  } else {
    result = 1;
  }
  free(info);
  return result;
}

int main(void) {
  int argc = 0;
  LPWSTR *argv = CommandLineToArgvW(GetCommandLineW(), &argc);
  if (!argv || argc != 3) {
    fprintf(stderr, "Usage: test_dll_init.exe <absolute ghostty-vt.dll path> <FileDescription>\n");
    if (argv) LocalFree(argv);
    return 1;
  }
  int passed = check_load_fails(argv[1]) && check_no_exports(argv[1]) &&
               check_description(argv[1], argv[2]);
  LocalFree(argv);
  if (!passed) return 1;
  printf("ghostty-vt.dll placeholder smoke: 3/3 checks passed\n");
  return 0;
}
