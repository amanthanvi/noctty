/*
 * The ghostty-vt.dll that the portable ZIP carries in place of the retired
 * libghostty-vt 0.1.0 library (scripts/package-windows.ps1 stages it from
 * zig-out\bin\ghostty-vt-stub\).
 *
 * The portable updater of noctty 1.3.125 to 1.3.136 refuses a payload without
 * a ghostty-vt.dll, and accepts one that is a signed PE of the right machine
 * with its line in the signed manifest. None of those updaters loads it. So
 * this file exists only to be present: it exports nothing, and it refuses to
 * initialise, so a program that loads it by the name upstream's
 * libghostty-vt 1.0 uses fails at LoadLibrary (ERROR_DLL_INIT_FAILED) instead
 * of binding to an old ABI. See the doc comment on
 * portable_zip_carries_legacy_entries in src/update/portable_apply.zig.
 *
 * Plain C, linked with no C runtime and this function as the entry point
 * (src/build/GhosttyVtStub.zig), so the image is this function and its
 * version resource. A Zig DLL brings Zig's start code (_DllMainCRTStartup) as
 * its entry and, unless built with -fno-dll-export-fns, exports it and the
 * TLS symbols. With -fsingle-threaded and -fno-dll-export-fns a Zig DLL is an
 * equivalent image, but its entry is std/start.zig's _DllMainCRTStartup; in C,
 * DllMain itself is the entry (docs/agents/log/build-release-ci.md,
 * GHOSTTY-VT-STUB trap 1).
 */

typedef int BOOL;
typedef unsigned long DWORD;
typedef void *HINSTANCE;

#define DLL_PROCESS_ATTACH 1

BOOL __stdcall DllMain(HINSTANCE instance, DWORD reason, void *reserved) {
  (void)instance;
  (void)reserved;
  /* FALSE on attach makes LoadLibrary fail. The loader then calls this again
   * with DLL_PROCESS_DETACH, which has nothing to undo. */
  return reason == DLL_PROCESS_ATTACH ? 0 : 1;
}
