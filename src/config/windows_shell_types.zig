//! Shared Windows shell profile type declarations.
//!
//! Kept separate from `windows_shell.zig` so presentation helpers can
//! depend on profile kinds without importing shell probing/spawn logic.

pub const ProfileKind = enum {
    wsl_default,
    wsl_distro,
    pwsh,
    powershell,
    git_bash,
    cmd,
    ssh,
    /// Defined by the user with `profile-command`.
    user,
    /// A Visual Studio instance's Developer Command Prompt (`VsDevCmd.bat`).
    vs_dev_cmd,
    /// A Visual Studio instance's Developer PowerShell (`Enter-VsDevShell`).
    vs_dev_shell,
};

pub const Utf8Console = enum {
    auto,
    always,
    never,
};
