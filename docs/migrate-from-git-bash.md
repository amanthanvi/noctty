# Migrate from Git Bash / mintty

Git Bash on Windows is mintty + MSYS2 bash. winghostty can launch the
same bash as a profile without mintty.

1. The profile picker lists **Git Bash** when `bash.exe` from Git for
   Windows is on PATH or under the standard `C:\Program Files\Git`
   install.
2. Shell integration injects automatically for a direct Git Bash
   launch. Prompt marks, OSC 7 cwd, and jump-to-prompt then work.
3. Colors and fonts come from Ghostty themes (`+list-themes`) and
   `font-family`, not `.minttyrc`.
4. `~/.bashrc` still applies inside the MSYS2 environment. Do not copy
   mintty-specific `Esc`/`Term` settings into Ghostty config.
5. UTF-8: `utf8-console = auto` covers `cmd` / Windows PowerShell 5.1.
   Git Bash is already a UTF-8 MSYS environment.
6. If you used mintty's "Open here" Explorer verb, the installer and
   portable first-run path register **Open winghostty here**.
