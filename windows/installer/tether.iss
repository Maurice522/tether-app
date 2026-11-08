; Inno Setup script for the Tether Windows installer.
; Build the app first (`flutter build windows --release`), then compile this
; with `iscc windows\installer\tether.iss` — output lands in windows\installer\Output.
; Per-user install (no admin prompt); the installer itself is unsigned, so
; Windows SmartScreen will warn once ("More info" -> "Run anyway").

#define AppName "Tether"
#define AppVersion "1.0.0"
#define AppExe "tether.exe"
#define BuildDir "..\..\build\windows\x64\runner\Release"

[Setup]
AppId={{8C6F2B1E-5D3A-4F7B-9A41-2E7C0D5B6A13}
AppName={#AppName}
AppVersion={#AppVersion}
AppPublisher=Maurice Rana
DefaultDirName={autopf}\{#AppName}
DefaultGroupName={#AppName}
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
Compression=lzma2
SolidCompression=yes
OutputDir=Output
OutputBaseFilename=Tether-Setup
SetupIconFile=..\runner\resources\app_icon.ico
UninstallDisplayIcon={app}\{#AppExe}
WizardStyle=modern

[Tasks]
Name: "desktopicon"; Description: "Create a desktop shortcut"; Flags: unchecked

[Files]
Source: "{#BuildDir}\*"; DestDir: "{app}"; Flags: recursesubdirs ignoreversion

[Icons]
Name: "{group}\{#AppName}"; Filename: "{app}\{#AppExe}"
Name: "{autodesktop}\{#AppName}"; Filename: "{app}\{#AppExe}"; Tasks: desktopicon

[Run]
Filename: "{app}\{#AppExe}"; Description: "Launch {#AppName}"; Flags: nowait postinstall skipifsilent
