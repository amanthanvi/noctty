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

    /// Where a profile of this kind comes from.
    pub fn source(self: ProfileKind) ProfileSource {
        return switch (self) {
            .wsl_default, .wsl_distro, .pwsh, .powershell, .git_bash, .cmd, .ssh => .detected,
            .user => .config,
            .vs_dev_cmd, .vs_dev_shell => .visual_studio,
        };
    }
};

/// Who made a profile: noctty found it on this machine, the user defined it,
/// or it is one of Visual Studio's developer shells.
pub const ProfileSource = enum {
    /// The local shells, the WSL distributions and the SSH hosts discovery
    /// finds.
    detected,
    /// Defined with `profile-command`.
    config,
    /// A Visual Studio instance's developer shell.
    visual_studio,
};

pub const Utf8Console = enum {
    auto,
    always,
    never,
};
