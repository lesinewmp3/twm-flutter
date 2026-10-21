; Inno Setup script: one-file installer for the Windows build.
; Built by .github/workflows/desktop.yml (paths are relative to this file).
; Installs per user (no admin rights needed).

[Setup]
AppId={{6B0D5A43-2F7E-4C1B-9E1A-7A3E1C2D9F10}
AppName=TWM Flutter
AppVersion=1.0.0
AppPublisher=TracePQM
DefaultDirName={localappdata}\Programs\TWM Flutter
DefaultGroupName=TWM Flutter
PrivilegesRequired=lowest
OutputDir=..\dist
OutputBaseFilename=TWM-Flutter-Setup
Compression=lzma2
SolidCompression=yes
ArchitecturesInstallIn64BitMode=x64compatible
SetupIconFile=..\app\windows\runner\resources\app_icon.ico
UninstallDisplayIcon={app}\twm_app.exe

[Languages]
Name: "ru"; MessagesFile: "compiler:Languages\Russian.isl"
Name: "en"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"

[Files]
Source: "..\app\build\windows\x64\runner\Release\*"; DestDir: "{app}"; Flags: recursesubdirs createallsubdirs ignoreversion

[Icons]
Name: "{group}\TWM Flutter"; Filename: "{app}\twm_app.exe"
Name: "{autodesktop}\TWM Flutter"; Filename: "{app}\twm_app.exe"; Tasks: desktopicon

[Run]
Filename: "{app}\twm_app.exe"; Description: "{cm:LaunchProgram,TWM Flutter}"; Flags: nowait postinstall skipifsilent
