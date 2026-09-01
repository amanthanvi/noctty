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
ChangesAssociations=yes
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

[Registry]
Root: HKLM; Subkey: "Software\Classes\CLSID\{{33368C6F-D328-410C-B225-26DC9F12C728}"; ValueType: string; ValueName: ""; ValueData: "noctty Terminal Handoff"; Flags: uninsdeletekey
Root: HKLM; Subkey: "Software\Classes\CLSID\{{33368C6F-D328-410C-B225-26DC9F12C728}\LocalServer32"; ValueType: string; ValueName: ""; ValueData: """{app}\noctty.exe"""
Root: HKLM; Subkey: "Software\Classes\CLSID\{{1D349824-21FB-46C7-ACF3-746EDC991D52}"; ValueType: string; ValueName: ""; ValueData: "noctty Terminal Handoff Proxy/Stub"; Flags: uninsdeletekey
Root: HKLM; Subkey: "Software\Classes\CLSID\{{1D349824-21FB-46C7-ACF3-746EDC991D52}\InprocServer32"; ValueType: string; ValueName: ""; ValueData: "{app}\noctty-terminal-handoff-proxy.dll"
Root: HKLM; Subkey: "Software\Classes\CLSID\{{1D349824-21FB-46C7-ACF3-746EDC991D52}\InprocServer32"; ValueType: string; ValueName: "ThreadingModel"; ValueData: "Both"
; Shared Interface\{IID}\ProxyStubClsid32 values are registered per-user by
; +register-default-terminal so their prior values can be restored safely.

Root: HKA; Subkey: "Software\Classes\Directory\shell\noctty"; ValueType: string; ValueName: ""; ValueData: "Open noctty here"; Flags: uninsdeletevalue uninsdeletekeyifempty
Root: HKA; Subkey: "Software\Classes\Directory\shell\noctty"; ValueType: string; ValueName: "Icon"; ValueData: "{app}\noctty.exe"; Flags: uninsdeletevalue uninsdeletekeyifempty
Root: HKA; Subkey: "Software\Classes\Directory\shell\noctty\command"; ValueType: string; ValueName: ""; ValueData: "{code:ShellMenuCommand}"; Flags: uninsdeletevalue uninsdeletekeyifempty

Root: HKA; Subkey: "Software\Classes\Directory\Background\shell\noctty"; ValueType: string; ValueName: ""; ValueData: "Open noctty here"; Flags: uninsdeletevalue uninsdeletekeyifempty
Root: HKA; Subkey: "Software\Classes\Directory\Background\shell\noctty"; ValueType: string; ValueName: "Icon"; ValueData: "{app}\noctty.exe"; Flags: uninsdeletevalue uninsdeletekeyifempty
Root: HKA; Subkey: "Software\Classes\Directory\Background\shell\noctty\command"; ValueType: string; ValueName: ""; ValueData: "{code:ShellMenuCommand}"; Flags: uninsdeletevalue uninsdeletekeyifempty

Root: HKA; Subkey: "Software\Classes\Drive\shell\noctty"; ValueType: string; ValueName: ""; ValueData: "Open noctty here"; Flags: uninsdeletevalue uninsdeletekeyifempty
Root: HKA; Subkey: "Software\Classes\Drive\shell\noctty"; ValueType: string; ValueName: "Icon"; ValueData: "{app}\noctty.exe"; Flags: uninsdeletevalue uninsdeletekeyifempty
Root: HKA; Subkey: "Software\Classes\Drive\shell\noctty\command"; ValueType: string; ValueName: ""; ValueData: "{code:ShellMenuCommand}"; Flags: uninsdeletevalue uninsdeletekeyifempty

[Run]
Filename: "{app}\noctty.exe"; Description: "Launch noctty"; Flags: nowait postinstall skipifsilent

[UninstallRun]
; Drop the uninstalling user's default-terminal selection before the files go
; away. Without this, HKCU keeps pointing DelegationTerminal at noctty's CLSID
; and the shared Interface proxy mappings at the deleted DLL, so every console
; launch fails activation and silently falls back to conhost. Runs before file
; removal; other users' selections are theirs to unregister. The ownership
; check preserves a newer registration made by another installed/portable copy.
Filename: "{app}\noctty.exe"; Parameters: "+unregister-default-terminal"; Flags: runhidden skipifdoesntexist; RunOnceId: "UnregisterDefaultTerminal"; Check: OwnsDefaultTerminalRegistration

[Code]
function OwnsDefaultTerminalRegistration(): Boolean;
var
  RegisteredCommand: String;
  RegisteredProxy: String;
  ExpectedCommand: String;
  ExpectedProxy: String;
begin
  ExpectedCommand := '"' + ExpandConstant('{app}\noctty.exe') + '"';
  ExpectedProxy := ExpandConstant('{app}\noctty-terminal-handoff-proxy.dll');
  Result :=
    RegQueryStringValue(
      HKCU,
      'Software\Classes\CLSID\{33368C6F-D328-410C-B225-26DC9F12C728}\LocalServer32',
      '',
      RegisteredCommand) and
    (CompareText(RegisteredCommand, ExpectedCommand) = 0) and
    RegQueryStringValue(
      HKCU,
      'Software\Classes\CLSID\{1D349824-21FB-46C7-ACF3-746EDC991D52}\InprocServer32',
      '',
      RegisteredProxy) and
    (CompareText(RegisteredProxy, ExpectedProxy) = 0);
end;

function ShellMenuCommand(Param: String): String;
var
  ExePath: String;
begin
  ExePath := ExpandConstant('{app}\noctty.exe');
  StringChangeEx(ExePath, '%', '%%', True);
  Result := AddQuotes(ExePath) + ' --working-directory="%V\."';
end;
