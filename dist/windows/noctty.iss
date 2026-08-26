#define AppName "noctty"
; AppId is Inno Setup's upgrade identity (registry-only, never shown to
; users). It intentionally keeps the pre-rename WingHostty value so
; existing installs upgrade in-place instead of installing side-by-side.
; Do not "fix" this to the new brand.
#define AppId "io.github.amanthanvi.winghostty"
#define AppUserModelId "io.github.amanthanvi.noctty"
#ifndef MyAppVersion
  #define MyAppVersion "0.0.0-dev"
#endif
#ifndef PackageArch
  #define PackageArch "x64"
#endif
#ifndef StageDir
  #error StageDir must be defined on the ISCC command line.
#endif
#ifndef OutputDir
  #error OutputDir must be defined on the ISCC command line.
#endif
#ifndef SourceDir
  #define SourceDir "."
#endif

[Setup]
AppId={#AppId}
AppName={#AppName}
AppVersion={#MyAppVersion}
AppPublisher=Aman Thanvi
AppPublisherURL=https://github.com/amanthanvi/noctty
AppSupportURL=https://github.com/amanthanvi/noctty/issues
AppUpdatesURL=https://github.com/amanthanvi/noctty/releases
DefaultDirName={autopf}\noctty
DefaultGroupName=noctty
DisableProgramGroupPage=yes
LicenseFile={#StageDir}\LICENSE
OutputDir={#OutputDir}
OutputBaseFilename=noctty-{#MyAppVersion}-windows-{#PackageArch}-setup
Compression=lzma
SolidCompression=yes
WizardStyle=modern
#if PackageArch == "arm64"
ArchitecturesAllowed=arm64
ArchitecturesInstallIn64BitMode=arm64
#else
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
#endif
ChangesAssociations=no
CloseApplications=yes
RestartApplications=yes
UninstallDisplayIcon={app}\noctty.exe
SetupIconFile={#SourceDir}\dist\windows\noctty.ico
VersionInfoVersion={#MyAppVersion}
VersionInfoTextVersion={#MyAppVersion}
VersionInfoProductVersion={#MyAppVersion}
VersionInfoProductTextVersion={#MyAppVersion}
VersionInfoCompany=Aman Thanvi
VersionInfoDescription=noctty Setup
VersionInfoProductName=noctty
VersionInfoOriginalFileName=noctty-{#MyAppVersion}-windows-{#PackageArch}-setup.exe

[Tasks]
Name: "desktopicon"; Description: "Create a desktop shortcut"; Flags: unchecked

[Files]
Source: "{#StageDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[InstallDelete]
; Remove pre-rename WingHostty binaries and shortcuts left behind when an
; existing install upgrades in-place (same AppId, new file names).
Type: files; Name: "{app}\winghostty.exe"
Type: files; Name: "{app}\winghostty.com"
Type: files; Name: "{group}\winghostty.lnk"
Type: files; Name: "{group}\Uninstall winghostty.lnk"
Type: files; Name: "{autodesktop}\winghostty.lnk"

[Icons]
Name: "{group}\noctty"; Filename: "{app}\noctty.exe"; AppUserModelID: "{#AppUserModelId}"
Name: "{group}\Uninstall noctty"; Filename: "{uninstallexe}"
Name: "{autodesktop}\noctty"; Filename: "{app}\noctty.exe"; Tasks: desktopicon; AppUserModelID: "{#AppUserModelId}"

[Run]
Filename: "{app}\noctty.exe"; Description: "Launch noctty"; Flags: nowait postinstall skipifsilent
