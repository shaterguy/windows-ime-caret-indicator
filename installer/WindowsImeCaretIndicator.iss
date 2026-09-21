#define MyAppName "Windows IME Caret Indicator"
#ifndef MyAppVersion
  #define MyAppVersion "0.1.0-dev1"
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
DefaultDirName={localappdata}\Programs\Windows IME Caret Indicator
DefaultGroupName={#MyAppName}
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
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
UsePreviousAppDir=yes

[Files]
Source: "..\artifacts\win-x64\{#MyAppExeName}"; DestDir: "{app}"; Flags: ignoreversion

[Icons]
Name: "{autoprograms}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"

[Registry]
Root: HKCU; Subkey: "Software\Microsoft\Windows\CurrentVersion\Run"; ValueType: string; ValueName: "WindowsImeCaretIndicator"; ValueData: """{app}\{#MyAppExeName}"""; Flags: uninsdeletevalue; Check: ShouldCreateStartupEntry

[Run]
Filename: "{app}\{#MyAppExeName}"; Description: "{cm:LaunchProgram,{#StringChange(MyAppName, '&', '&&')}}"; Flags: postinstall nowait skipifsilent unchecked

[UninstallDelete]
Type: files; Name: "{localappdata}\WindowsImeCaretIndicator\settings.json"
Type: dirifempty; Name: "{localappdata}\WindowsImeCaretIndicator"

[Code]
function ShouldCreateStartupEntry(): Boolean;
begin
  Result := not FileExists(
    ExpandConstant('{localappdata}\WindowsImeCaretIndicator\settings.json'));
end;

procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
begin
  if CurUninstallStep = usUninstall then
    RegDeleteValue(
      HKCU,
      'Software\Microsoft\Windows\CurrentVersion\Run',
      'WindowsImeCaretIndicator');
end;
