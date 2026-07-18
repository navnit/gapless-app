#define AppName "Gapless"
#define AppVersion GetEnv("GAPLESS_VERSION")
#define BuildDir GetEnv("GAPLESS_WINDOWS_BUNDLE")
#define OutputDir GetEnv("GAPLESS_OUTPUT_DIR")

[Setup]
AppId={{A42DC45D-AEEC-4D95-984A-E389D2A683AF}
AppName={#AppName}
AppVersion={#AppVersion}
DefaultDirName={autopf}\Gapless
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
Compression=lzma2
SolidCompression=yes
OutputDir={#OutputDir}
OutputBaseFilename=Gapless-{#AppVersion}-windows-x64
PrivilegesRequired=admin
UninstallDisplayIcon={app}\gapless.exe
WizardStyle=modern

[Files]
Source: "{#BuildDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{autoprograms}\Gapless"; Filename: "{app}\gapless.exe"
Name: "{autodesktop}\Gapless"; Filename: "{app}\gapless.exe"; Tasks: desktopicon

[Tasks]
Name: "desktopicon"; Description: "Create a desktop shortcut"; Flags: unchecked

[Run]
Filename: "{app}\gapless.exe"; Description: "Launch Gapless"; Flags: nowait postinstall skipifsilent
