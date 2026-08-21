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
};

pub const Utf8Console = enum {
    auto,
    always,
    never,
};
