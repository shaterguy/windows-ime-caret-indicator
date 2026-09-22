#define MyAppName "Windows IME Caret Indicator"
#ifndef MyAppVersion
  #define MyAppVersion "0.1.0"
#endif
#define MyAppExeName "WindowsImeCaretIndicator.exe"
#define MyAppPublisher "SHatergUY"
#define MyAppURL "https://github.com/shaterguy/windows-ime-caret-indicator"

[Setup]
AppId={{77D81AE7-1E91-56DB-B694-8E60C764A76D}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppPublisher={#MyAppPublisher}
AppPublisherURL={#MyAppURL}
AppSupportURL={#MyAppURL}/issues
AppUpdatesURL={#MyAppURL}/releases
DefaultDirName={autopf}\Windows IME Caret Indicator
DefaultGroupName={#MyAppName}
DisableProgramGroupPage=yes
DisableDirPage=yes
PrivilegesRequired=admin
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0
OutputDir=..\artifacts\installer
OutputBaseFilename=WindowsImeCaretIndicator-Setup-{#MyAppVersion}
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
UninstallDisplayIcon={app}\{#MyAppExeName}
AppMutex=Local\WindowsImeCaretIndicator
CloseApplications=yes
RestartApplications=no
RestartIfNeededByRun=no
UsePreviousAppDir=no

[Files]
Source: "..\artifacts\win-x64\{#MyAppExeName}"; DestDir: "{app}"; Flags: ignoreversion

[Icons]
Name: "{autoprograms}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"

[Run]
Filename: "{app}\{#MyAppExeName}"; Parameters: "--migrate-v010"; Flags: runhidden runasoriginaluser
Filename: "{app}\{#MyAppExeName}"; Description: "{cm:LaunchProgram,{#StringChange(MyAppName, '&', '&&')}}"; Flags: postinstall nowait skipifsilent runasoriginaluser

[Code]
const
  CurrentRunKey = 'Software\Microsoft\Windows\CurrentVersion\Run';
  CurrentRunValueName = 'WindowsImeCaretIndicator.ProgramFiles';
  CurrentIdentityKey = 'Software\SHatergUY\Windows IME Caret Indicator';
  CurrentGeneration = 'programfiles-v2';

function IsCurrentCredentialProductState(): Boolean;
var
  Generation: String;
  ExecutablePath: String;
begin
  Result :=
    RegQueryStringValue(
      HKCU,
      CurrentIdentityKey,
      'Generation',
      Generation) and
    RegQueryStringValue(
      HKCU,
      CurrentIdentityKey,
      'ExecutablePath',
      ExecutablePath) and
    (Generation = CurrentGeneration) and
    (CompareText(
       ExecutablePath,
       ExpandConstant('{app}\{#MyAppExeName}')) = 0);
end;

procedure CurUninstallStepChanged(
  CurUninstallStep: TUninstallStep);
var
  RunValue: String;
  ExpectedRunValue: String;
begin
  if (CurUninstallStep <> usUninstall) or
     (not IsCurrentCredentialProductState()) then
  begin
    exit;
  end;

  ExpectedRunValue :=
    '"' + ExpandConstant('{app}\{#MyAppExeName}') + '"';

  if RegQueryStringValue(
       HKCU,
       CurrentRunKey,
       CurrentRunValueName,
       RunValue) and
     (CompareText(RunValue, ExpectedRunValue) = 0) then
  begin
    RegDeleteValue(
      HKCU,
      CurrentRunKey,
      CurrentRunValueName);
  end;

  DeleteFile(
    ExpandConstant(
      '{localappdata}\WindowsImeCaretIndicator\state-v2.json'));

  RegDeleteValue(
    HKCU,
    CurrentIdentityKey,
    'Generation');
  RegDeleteValue(
    HKCU,
    CurrentIdentityKey,
    'ExecutablePath');
end;
