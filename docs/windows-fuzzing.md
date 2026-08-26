# Incremental Win32 fuzzing (C32)

The Wave 1 audit confirmed clipboard and drag-drop share the
CVE-2026-26982 confirm path and never route through `textCallback`.

Incremental fuzzing reuses upstream's corpus approach on fork-only
surfaces:

1. Paste / drop payloads (`win32_paste_protection.inspect`)
2. ConPTY I/O (`src/pty.zig` + bundled `conpty.dll` path)
3. Session-state JSON (`win32_session_state.parseAlloc`)
4. Single-instance IPC frames (`win32_ipc`)

No AFL++ harness is wired in this increment. Add a corpus directory
under `test/fuzz/` when the first target lands; do not add a silent
CI gate before a baseline exists (same rule as C01).
