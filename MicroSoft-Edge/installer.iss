#define AppName "Windows-Scripts - Remove Edge"
#define AppVersion "1.3.1"
#define AppPublisher "Shourav"
#define AppURL "https://github.com/rhshourav"
#define AppExeName "Remove Edge (Windows-Scripts).lnk"
#define ScriptName "Remove-Edge-Menu.ps1"

[Setup]
AppId={{A2E1E0C4-9B7A-4C1B-9B61-9EE8A0A2D2B1}
AppName={#AppName}
AppVersion={#AppVersion}
AppPublisher={#AppPublisher}
AppPublisherURL={#AppURL}
AppSupportURL={#AppURL}
AppUpdatesURL={#AppURL}
DefaultDirName={autopf}\Windows-Scripts\RemoveEdge
DefaultGroupName=Windows-Scripts
DisableProgramGroupPage=yes
OutputDir=dist
OutputBaseFilename=Windows-Scripts_RemoveEdge_{#AppVersion}_Setup
Compression=lzma2
SolidCompression=yes
WizardStyle=modern

; Windows 10 1903 (19H1) build 18362 => MinVersion 10.0.18362
MinVersion=10.0.18362
ArchitecturesAllowed=x64 arm64
ArchitecturesInstallIn64BitMode=x64 arm64

; Optional icon (remove these 2 lines if you don't have an .ico)
SetupIconFile=Windows-Scripts.ico
UninstallDisplayIcon={app}\Windows-Scripts.ico

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Files]
Source: "{#ScriptName}"; DestDir: "{app}"; Flags: ignoreversion
; Optional assets:
Source: "Windows-Scripts.ico"; DestDir: "{app}"; Flags: ignoreversion skipifsourcedoesntexist
Source: "LICENSE.txt"; DestDir: "{app}"; Flags: ignoreversion skipifsourcedoesntexist
Source: "README.txt"; DestDir: "{app}"; Flags: ignoreversion skipifsourcedoesntexist

[Icons]
Name: "{group}\Remove Edge (Interactive)"; Filename: "powershell.exe"; \
  Parameters: "-NoProfile -ExecutionPolicy Bypass -File ""{app}\{#ScriptName}"""; \
  WorkingDir: "{app}"; IconFilename: "{app}\Windows-Scripts.ico"; \
  Comment: "Windows-Scripts | Remove Microsoft Edge (Best-Effort)"

; Optional Desktop shortcut (comment out if you don't want it)
Name: "{commondesktop}\Remove Edge (Windows-Scripts)"; Filename: "powershell.exe"; \
  Parameters: "-NoProfile -ExecutionPolicy Bypass -File ""{app}\{#ScriptName}"""; \
  WorkingDir: "{app}"; IconFilename: "{app}\Windows-Scripts.ico"; Tasks: desktopicon

[Tasks]
Name: "desktopicon"; Description: "Create a &Desktop shortcut"; GroupDescription: "Additional icons:"; Flags: unchecked

[Run]
; Optional: Launch after install (unchecked by default to avoid surprise UAC)
Filename: "powershell.exe"; \
  Parameters: "-NoProfile -ExecutionPolicy Bypass -File ""{app}\{#ScriptName}"""; \
  WorkingDir: "{app}"; \
  Description: "Launch Remove Edge (Interactive)"; Flags: postinstall shellexec skipifsilent unchecked

[UninstallRun]
; Nothing required. Uninstaller removes installed files automatically.
