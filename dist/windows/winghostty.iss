#define AppName "winghostty"
#define AppId "io.github.amanthanvi.winghostty"
#define AppUserModelId "com.ghostty.winghostty"
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
AppPublisherURL=https://github.com/amanthanvi/winghostty
AppSupportURL=https://github.com/amanthanvi/winghostty/issues
AppUpdatesURL=https://github.com/amanthanvi/winghostty/releases
DefaultDirName={autopf}\winghostty
DefaultGroupName=winghostty
DisableProgramGroupPage=yes
LicenseFile={#StageDir}\LICENSE
OutputDir={#OutputDir}
OutputBaseFilename=winghostty-{#MyAppVersion}-windows-{#PackageArch}-setup
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
UninstallDisplayIcon={app}\winghostty.exe
SetupIconFile={#SourceDir}\dist\windows\winghostty.ico
VersionInfoVersion={#MyAppVersion}
VersionInfoTextVersion={#MyAppVersion}
VersionInfoProductVersion={#MyAppVersion}
VersionInfoProductTextVersion={#MyAppVersion}
VersionInfoCompany=Aman Thanvi
VersionInfoDescription=winghostty Setup
VersionInfoProductName=winghostty
VersionInfoOriginalFileName=winghostty-{#MyAppVersion}-windows-{#PackageArch}-setup.exe

[Tasks]
Name: "desktopicon"; Description: "Create a desktop shortcut"; Flags: unchecked

[Files]
Source: "{#StageDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\winghostty"; Filename: "{app}\winghostty.exe"; AppUserModelID: "{#AppUserModelId}"
Name: "{group}\Uninstall winghostty"; Filename: "{uninstallexe}"
Name: "{autodesktop}\winghostty"; Filename: "{app}\winghostty.exe"; Tasks: desktopicon; AppUserModelID: "{#AppUserModelId}"

[Registry]
Root: HKCU; Subkey: "Software\Classes\Directory\shell\winghostty"; ValueType: string; ValueName: ""; ValueData: "Open winghostty here"; Flags: uninsdeletekey
Root: HKCU; Subkey: "Software\Classes\Directory\shell\winghostty"; ValueType: string; ValueName: "Icon"; ValueData: "{app}\winghostty.exe"
Root: HKCU; Subkey: "Software\Classes\Directory\shell\winghostty\command"; ValueType: string; ValueName: ""; ValueData: """{app}\winghostty.exe"" --working-directory=""%1"""
Root: HKCU; Subkey: "Software\Classes\Directory\Background\shell\winghostty"; ValueType: string; ValueName: ""; ValueData: "Open winghostty here"; Flags: uninsdeletekey
Root: HKCU; Subkey: "Software\Classes\Directory\Background\shell\winghostty"; ValueType: string; ValueName: "Icon"; ValueData: "{app}\winghostty.exe"
Root: HKCU; Subkey: "Software\Classes\Directory\Background\shell\winghostty\command"; ValueType: string; ValueName: ""; ValueData: """{app}\winghostty.exe"" --working-directory=""%V"""

[Run]
Filename: "{app}\winghostty.exe"; Description: "Launch winghostty"; Flags: nowait postinstall skipifsilent
