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
; Setup asks Restart Manager to close what holds the files it replaces. The
; bundled OpenConsole.exe runs once per pane as a headless ConPTY host, and
; Restart Manager classes it RmUnknownApp, which only a forced shutdown can
; close: with it registered, every non-forced RmShutdown failed with 351 in
; under 100 ms before noctty saw any message, and Setup aborted (exit 5 under
; /SUPPRESSMSGBOXES). It exits with noctty (measured: no OpenConsole child
; survived once Restart Manager had closed noctty), so leaving it out still
; frees the file. noctty.exe, conpty.dll and the handoff proxy stay registered.
; Needs Inno Setup 6.4.2 or later. Keep CloseApplications off "force": a
; forced close kills the programs running in noctty's terminals.
CloseApplications=yes
CloseApplicationsFilterExcludes=OpenConsole.exe
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
; The recursive stage rule includes the bundled ConPTY pair and its license.
Source: "{#StageDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[InstallDelete]
; Always clear a previously bundled ConPTY before staging this package.
Type: files; Name: "{app}\conpty.dll"
Type: files; Name: "{app}\OpenConsole.exe"
Type: files; Name: "{app}\LICENSE-conpty.txt"
; Remove pre-rename WingHostty binaries and shortcuts left behind when an
; existing install upgrades in-place (same AppId, new file names).
Type: files; Name: "{app}\winghostty.exe"
Type: files; Name: "{app}\winghostty.com"
Type: files; Name: "{group}\winghostty.lnk"
Type: files; Name: "{group}\Uninstall winghostty.lnk"
Type: files; Name: "{autodesktop}\winghostty.lnk"

[Icons]
; AppUserModelToastActivatorCLSID is the toast activator registered under
; [Registry] below (src/apprt/win32_toast_activator.zig, clsid_text): Action
; Center hands a click on a noctty toast to that class.
Name: "{group}\noctty"; Filename: "{app}\noctty.exe"; AppUserModelID: "{#AppUserModelId}"; AppUserModelToastActivatorCLSID: "3E21F05E-C82D-4E45-AA7D-2EC361AD6C3E"
Name: "{group}\Uninstall noctty"; Filename: "{uninstallexe}"
Name: "{autodesktop}\noctty"; Filename: "{app}\noctty.exe"; Tasks: desktopicon; AppUserModelID: "{#AppUserModelId}"; AppUserModelToastActivatorCLSID: "3E21F05E-C82D-4E45-AA7D-2EC361AD6C3E"

[Registry]
Root: HKLM; Subkey: "Software\Classes\CLSID\{{33368C6F-D328-410C-B225-26DC9F12C728}"; ValueType: string; ValueName: ""; ValueData: "noctty Terminal Handoff"; Flags: uninsdeletekey
Root: HKLM; Subkey: "Software\Classes\CLSID\{{33368C6F-D328-410C-B225-26DC9F12C728}\LocalServer32"; ValueType: string; ValueName: ""; ValueData: """{app}\noctty.exe"""
Root: HKLM; Subkey: "Software\Classes\CLSID\{{1D349824-21FB-46C7-ACF3-746EDC991D52}"; ValueType: string; ValueName: ""; ValueData: "noctty Terminal Handoff Proxy/Stub"; Flags: uninsdeletekey
Root: HKLM; Subkey: "Software\Classes\CLSID\{{1D349824-21FB-46C7-ACF3-746EDC991D52}\InprocServer32"; ValueType: string; ValueName: ""; ValueData: "{app}\noctty-terminal-handoff-proxy.dll"
Root: HKLM; Subkey: "Software\Classes\CLSID\{{1D349824-21FB-46C7-ACF3-746EDC991D52}\InprocServer32"; ValueType: string; ValueName: "ThreadingModel"; ValueData: "Both"
; Shared Interface\{IID}\ProxyStubClsid32 values are registered per-user by
; +register-default-terminal so their prior values can be restored safely.

; The toast activator. COM starts this command (and appends -Embedding) when
; a toast is clicked in Action Center and no running noctty registered the
; class; a running installed copy registers it itself. The per-user
; CustomActivator value that points the AUMID here is written by the app
; (win32_aumid.zig) and removed at uninstall (CurUninstallStepChanged).
Root: HKA; Subkey: "Software\Classes\CLSID\{{3E21F05E-C82D-4E45-AA7D-2EC361AD6C3E}"; ValueType: string; ValueName: ""; ValueData: "noctty Toast Activator"; Flags: uninsdeletekey
Root: HKA; Subkey: "Software\Classes\CLSID\{{3E21F05E-C82D-4E45-AA7D-2EC361AD6C3E}\LocalServer32"; ValueType: string; ValueName: ""; ValueData: """{app}\noctty.exe"" -ToastActivated"

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
; Both entries start noctty through Explorer, which runs the file as the
; logged-on user's shell and so never elevated. runasoriginaluser would not be
; enough on its own: the Inno Setup help says it "is the default behavior when
; the postinstall flag is used", but also that it has no effect when Setup was
; started with "Run as administrator" or from an already-elevated process, and
; then "Launch noctty" would open an Administrator terminal. It is kept anyway
; for a Setup that was started the ordinary way.
Filename: "{win}\explorer.exe"; Parameters: """{app}\noctty.exe"""; Description: "Launch noctty"; Flags: nowait postinstall skipifsilent runasoriginaluser
; The in-app Install quits noctty and runs this Setup silently with
; /RELAUNCH=1, so nothing else starts noctty again: /RESTARTAPPLICATIONS only
; restarts what Restart Manager closed and registered for a restart, noctty has
; already exited by then, and another noctty process does not register while
; this Setup runs.
; Install starts Setup with ShellExecute "runas", the case where
; runasoriginaluser does nothing, hence Explorer here too.
Filename: "{win}\explorer.exe"; Parameters: """{app}\noctty.exe"""; Flags: nowait runasoriginaluser; Check: RelaunchAfterSilentSetup

[Code]
{ True for the silent apply that noctty starts from its update notice, which
  passes /RELAUNCH=1. A silent install started any other way (WinGet,
  Chocolatey, a script) does not pass it, so this entry does not start noctty
  there. RestartApplications does instead, when the noctty that owns the saved
  session agreed to close: it registers for Setup's restart while agreeing.
  Setup restarts applications after the [Run] entries and before the finished
  page, so in a wizard run a "Launch noctty" left checked starts noctty a
  second time, which opens one more window. }
function RelaunchAfterSilentSetup(): Boolean;
begin
  Result := WizardSilent and (ExpandConstant('{param:RELAUNCH|0}') = '1');
end;

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
  Result := AddQuotes(ExePath) + ' --single-instance=false --working-directory="%V\."';
end;

{ The uninstalling user's AUMID registration names the toast activator whose
  class key this uninstall removes. Without the class, a click on a toast
  from a portable copy left behind would ask COM for a server that is gone.
  Only a value naming this activator is removed: the rest of the key is
  shared with portable copies. Other users' values are theirs. }
procedure RemoveToastActivatorValue();
var
  Registered: String;
begin
  if RegQueryStringValue(HKCU, 'Software\Classes\AppUserModelId\{#AppUserModelId}', 'CustomActivator', Registered) and
    (CompareText(Registered, '{3E21F05E-C82D-4E45-AA7D-2EC361AD6C3E}') = 0) then
    RegDeleteValue(HKCU, 'Software\Classes\AppUserModelId\{#AppUserModelId}', 'CustomActivator');
end;

{ Drop the uninstalling user's default-terminal selection before the files go
  away. Without this, HKCU keeps pointing DelegationTerminal at noctty's CLSID
  and the shared Interface proxy mappings at the deleted DLL, so every console
  launch fails activation and silently falls back to conhost. Other users'
  selections are theirs to unregister. The ownership check preserves a newer
  registration made by another installed/portable copy.

  This is deliberately code and not an [UninstallRun] entry with a Check:
  Inno Setup evaluates an [UninstallRun] Check while INSTALLING, so on a fresh
  install (nothing registered yet) it returned False and the entry was never
  recorded in the uninstall log, and uninstall then left noctty registered.
  Measured with a throwaway installer: the Check ran once, at install time,
  and never at uninstall. CurUninstallStepChanged runs in the uninstaller,
  before the files are removed. }
procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
var
  ExePath: String;
  ResultCode: Integer;
begin
  if CurUninstallStep <> usUninstall then
    Exit;
  RemoveToastActivatorValue();
  ExePath := ExpandConstant('{app}\noctty.exe');
  if not (FileExists(ExePath) and OwnsDefaultTerminalRegistration()) then
    Exit;
  { The uninstall goes on either way, but a registration left pointing at the
    removed files makes every console launch fall back to conhost, so say so. }
  if not Exec(ExePath, '+unregister-default-terminal', '', SW_HIDE, ewWaitUntilTerminated, ResultCode)
    or (ResultCode <> 0) then
  begin
    Log('+unregister-default-terminal did not finish: result ' + IntToStr(ResultCode));
    { Only an attended uninstall gets the box: /SILENT and /VERYSILENT without
      /SUPPRESSMSGBOXES would otherwise wait for a click nobody can give. }
    if not UninstallSilent then
      MsgBox(
        'noctty could not remove its default terminal registration, so Windows may keep trying to start it after it is uninstalled.' + #13#10#13#10 +
        'To clear it, reinstall noctty, run "noctty +unregister-default-terminal", and uninstall again, or pick another default terminal in Windows Settings.',
        mbInformation, MB_OK);
  end;
end;
