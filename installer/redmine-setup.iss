; Installer offline di Redmine (Ruby + PostgreSQL + wsw precompilati) - Inno Setup 7
; Compilazione: Build-Installer.ps1 (prepara "stage\" e richiama ISCC)
;
; Installazione silenziosa:
;   Redmine-<versione>-Setup.exe /VERYSILENT /SUPPRESSMSGBOXES /DIR=D:\Redmine
;       /HTTPPORT=8080 /PGPORT=5433 /REDMINELANG=en /TASKS=firewall /LOG=setup.log
; Il runtime Visual C++ incluso viene installato solo se manca o e' piu' vecchio
; (/FORCEVCREDIST lo esegue comunque, per i test)
; Disinstallazione silenziosa (i dati restano, salvo /REMOVEDATA):
;   unins000.exe /VERYSILENT /SUPPRESSMSGBOXES [/REMOVEDATA]

#ifndef AppVersion
  #define AppVersion "7.0.2"
#endif
#ifndef StageDir
  #define StageDir "stage"
#endif
; Runtime Visual C++ x64 richiesto da PostgreSQL (vcruntime140.dll): versione passata da Build-Installer.ps1
#ifndef VcRedist
  #define VcRedist "cache\vc_redist.x64.exe"
#endif
#ifndef VcRedistVersion
  #define VcRedistVersion "14.51.36247.0"
  #define VcRedistMinor "51"
  #define VcRedistBld "36247"
#endif

[Setup]
AppId={{8C3F2A51-6B7E-4D2A-9C1E-5A7B3D9E2F10}
AppName=Redmine
AppVersion={#AppVersion}
AppVerName=Redmine {#AppVersion}
AppPublisher=Redmine (portable build)
AppPublisherURL=https://www.redmine.org
DefaultDirName={sd}\Redmine
DisableProgramGroupPage=yes
DirExistsWarning=no
UsePreviousAppDir=yes
PrivilegesRequired=admin
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
; tar.exe, Get-NetTCPConnection e i servizi ritardati richiedono Windows 10 1809 / Server 2019
MinVersion=10.0.17763
OutputDir=dist
OutputBaseFilename=Redmine-{#AppVersion}-Setup
Compression=lzma2/max
SolidCompression=yes
LZMAUseSeparateProcess=yes
LZMANumBlockThreads=4
WizardStyle=modern
SetupLogging=yes
CloseApplications=no
UninstallDisplayName=Redmine {#AppVersion}
; Database, allegati e log non fanno parte del pacchetto
ExtraDiskSpaceRequired=314572800
#ifexist StageDir + "\redmine\doc\COPYING"
LicenseFile={#StageDir}\redmine\doc\COPYING
#endif

[Languages]
Name: "it"; MessagesFile: "compiler:Languages\Italian.isl"
Name: "en"; MessagesFile: "compiler:Default.isl"

[CustomMessages]
it.PortsCaption=Porte di rete
it.PortsDescription=Su quali porte devono rispondere Redmine e PostgreSQL?
it.PortsSubCaption=Redmine e' raggiungibile via HTTP sulla prima porta. PostgreSQL ascolta solo su localhost.
it.HttpPortLabel=Porta HTTP di &Redmine:
it.PgPortLabel=Porta di &PostgreSQL:
it.LangCaption=Lingua
it.LangDescription=Lingua dei dati iniziali di Redmine
it.LangSubCaption=Stati, trackers, ruoli e priorita' predefiniti vengono creati in questa lingua. Ogni utente puo' poi scegliere la lingua dell'interfaccia.
it.FirewallTask=Apri la porta HTTP nel firewall di Windows (accesso da altri computer)
it.ErrPath=Il percorso di installazione non deve contenere spazi o caratteri non ASCII ed essere lungo al massimo 60 caratteri.
it.ErrPortValue=Le porte devono essere numeri tra 1 e 65535.
it.ErrPortSame=La porta HTTP e quella di PostgreSQL devono essere diverse.
it.ErrPortBusy=La porta %1 e' gia' in uso da un altro programma. Sceglierne un'altra.
it.Configuring=Configurazione di PostgreSQL e Redmine in corso (qualche minuto)...
it.ConfigFailed=La configurazione di Redmine non e' riuscita (codice %1).%n%nDettagli nel log:%n%2%n%nDopo aver risolto il problema si puo' rilanciare l'installazione.
it.VcRedistInstalling=Installazione del runtime Microsoft Visual C++ (richiesto da PostgreSQL)...
it.VcRedistFailed=L'installazione del runtime Microsoft Visual C++ non e' riuscita (codice %1). Installare vc_redist.x64.exe da https://aka.ms/vc14/vc_redist.x64.exe e ripetere l'installazione.
it.OpenRedmine=Apri Redmine nel browser
it.RemoveData=Eliminare anche database, allegati, credenziali e log?%n%nScegliendo No restano in %1 e verranno riutilizzati da una nuova installazione.
it.DataKept=I dati di Redmine sono stati conservati in %1.
en.PortsCaption=Network ports
en.PortsDescription=Which ports should Redmine and PostgreSQL listen on?
en.PortsSubCaption=Redmine is served over HTTP on the first port. PostgreSQL only listens on localhost.
en.HttpPortLabel=&Redmine HTTP port:
en.PgPortLabel=&PostgreSQL port:
en.LangCaption=Language
en.LangDescription=Language of the Redmine default data
en.LangSubCaption=Default statuses, trackers, roles and priorities are created in this language. Every user can then pick the interface language.
en.FirewallTask=Open the HTTP port in Windows Firewall (access from other computers)
en.ErrPath=The installation path must not contain spaces or non-ASCII characters and must be at most 60 characters long.
en.ErrPortValue=Ports must be numbers between 1 and 65535.
en.ErrPortSame=The HTTP and PostgreSQL ports must be different.
en.ErrPortBusy=Port %1 is already used by another program. Please choose another one.
en.Configuring=Configuring PostgreSQL and Redmine (this takes a few minutes)...
en.ConfigFailed=The Redmine configuration failed (code %1).%n%nDetails in the log:%n%2%n%nOnce the problem is fixed the setup can be run again.
en.VcRedistInstalling=Installing the Microsoft Visual C++ runtime (required by PostgreSQL)...
en.VcRedistFailed=The Microsoft Visual C++ runtime installation failed (code %1). Install vc_redist.x64.exe from https://aka.ms/vc14/vc_redist.x64.exe and run the setup again.
en.OpenRedmine=Open Redmine in the browser
en.RemoveData=Also delete the database, attachments, credentials and logs?%n%nIf you choose No they stay in %1 and are reused by a new installation.
en.DataKept=The Redmine data has been kept in %1.

[Tasks]
Name: "firewall"; Description: "{cm:FirewallTask}"; Flags: unchecked

[Files]
Source: "{#VcRedist}"; DestName: "vc_redist.x64.exe"; Flags: dontcopy
Source: "{#StageDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[INI]
Filename: "{app}\Redmine.url"; Section: "InternetShortcut"; Key: "URL"; String: "http://localhost:{code:GetHttpPort}/"

[Icons]
Name: "{autoprograms}\Redmine"; Filename: "{app}\Redmine.url"

[Run]
Filename: "http://localhost:{code:GetHttpPort}/"; Description: "{cm:OpenRedmine}"; Flags: postinstall shellexec nowait skipifsilent; Check: ConfigSucceeded

[UninstallRun]
; Rimuove i servizi (e la regola firewall) prima che vengano cancellati i file
Filename: "{sysnative}\WindowsPowerShell\v1.0\powershell.exe"; Parameters: "-NoProfile -ExecutionPolicy Bypass -File ""{app}\setup\Uninstall-Redmine.ps1"" -InstallDir ""{app}"""; Flags: runhidden waituntilterminated; RunOnceId: "RemoveServices"

[UninstallDelete]
Type: files; Name: "{app}\Redmine.url"

[Code]
const
  RedmineService = 'Redmine';
  PgService      = 'RedminePostgreSQL';

var
  PortsPage: TInputQueryWizardPage;
  LangPage: TInputOptionWizardPage;
  LangCodes: TArrayOfString;
  ConfigExitCode: Integer;

function ServiceInstalled(const Name: String): Boolean;
begin
  Result := RegKeyExists(HKLM, 'SYSTEM\CurrentControlSet\Services\' + Name);
end;

function PowerShellExe: String;
begin
  Result := ExpandConstant('{sysnative}\WindowsPowerShell\v1.0\powershell.exe');
end;

function RunPowerShell(const Command: String): Integer;
var
  Code: Integer;
begin
  if not Exec(PowerShellExe, '-NoProfile -ExecutionPolicy Bypass -Command "' + Command + '"',
              '', SW_HIDE, ewWaitUntilTerminated, Code) then
    Code := -1;
  Result := Code;
end;

function HasParam(const Name: String): Boolean;
var
  I: Integer;
begin
  Result := False;
  for I := 1 to ParamCount do
    if CompareText(ParamStr(I), Name) = 0 then
      Result := True;
end;

{ --- Runtime Visual C++ (vcruntime140.dll, usata da postgres.exe e libpq.dll) --- }

const
  VcRuntimeKey = 'SOFTWARE\Microsoft\VisualStudio\14.0\VC\Runtimes\x64';

{ True se e' installato un runtime x64 almeno pari a quello incluso nell'installer }
function VcRuntimeCurrent: Boolean;
var
  Installed, Minor, Bld: Cardinal;
begin
  Result := RegQueryDWordValue(HKLM64, VcRuntimeKey, 'Installed', Installed) and (Installed = 1) and
            RegQueryDWordValue(HKLM64, VcRuntimeKey, 'Minor', Minor) and
            RegQueryDWordValue(HKLM64, VcRuntimeKey, 'Bld', Bld) and
            ((Minor > {#VcRedistMinor}) or ((Minor = {#VcRedistMinor}) and (Bld >= {#VcRedistBld}))) and
            FileExists(ExpandConstant('{sys}\vcruntime140.dll'));
end;

{ Stringa vuota se il runtime e' a posto, altrimenti il messaggio d'errore }
function EnsureVcRuntime: String;
var
  Code: Integer;
begin
  Result := '';
  if VcRuntimeCurrent and not HasParam('/FORCEVCREDIST') then begin
    Log('Runtime Visual C++ x64 gia'' presente e aggiornato (incluso: {#VcRedistVersion})');
    Exit;
  end;
  Log('Installazione del runtime Visual C++ x64 {#VcRedistVersion}');
  WizardForm.PreparingLabel.Caption := CustomMessage('VcRedistInstalling');
  WizardForm.PreparingLabel.Visible := True;
  ExtractTemporaryFile('vc_redist.x64.exe');
  if not Exec(ExpandConstant('{tmp}\vc_redist.x64.exe'), '/install /quiet /norestart', '',
              SW_HIDE, ewWaitUntilTerminated, Code) then
    Code := -1;
  Log('vc_redist.x64.exe terminato con codice ' + IntToStr(Code));
  { 1638: e' gia' installata una versione piu' recente; 3010: riavvio consigliato, il runtime e' gia' utilizzabile }
  if (Code <> 0) and (Code <> 1638) and (Code <> 3010) then
    Result := FmtMessage(CustomMessage('VcRedistFailed'), [IntToStr(Code)]);
end;

{ --- Valori scelti (pagine, riga di comando o installazione precedente) --- }

function GetHttpPort(Param: String): String;
begin
  Result := Trim(PortsPage.Values[0]);
end;

function GetPgPort: String;
begin
  Result := Trim(PortsPage.Values[1]);
end;

function GetRedmineLang: String;
begin
  Result := LangCodes[LangPage.SelectedValueIndex];
end;

function ConfigSucceeded: Boolean;
begin
  Result := ConfigExitCode = 0;
end;

{ --- Validazioni --- }

function ValidPath(const Path: String): Boolean;
var
  I: Integer;
begin
  Result := (Length(Path) <= 60) and (Pos(' ', Path) = 0);
  for I := 1 to Length(Path) do
    if Ord(Path[I]) > 127 then
      Result := False;
end;

function PortInUse(const Port: Integer): Boolean;
begin
  Result := RunPowerShell('if (Get-NetTCPConnection -State Listen -LocalPort ' + IntToStr(Port) +
                          ' -ErrorAction SilentlyContinue) { exit 1 } else { exit 0 }') = 1;
end;

{ Stringa vuota se le porte vanno bene, altrimenti il messaggio d'errore }
function CheckPorts: String;
var
  Http, Pg: Integer;
begin
  Result := '';
  Http := StrToIntDef(GetHttpPort(''), 0);
  Pg := StrToIntDef(GetPgPort, 0);
  if (Http < 1) or (Http > 65535) or (Pg < 1) or (Pg > 65535) then
    Result := CustomMessage('ErrPortValue')
  else if Http = Pg then
    Result := CustomMessage('ErrPortSame')
  { In un aggiornamento le porte sono occupate dai servizi di Redmine stessi }
  else if not ServiceInstalled(RedmineService) then begin
    if PortInUse(Http) then
      Result := FmtMessage(CustomMessage('ErrPortBusy'), [IntToStr(Http)])
    else if PortInUse(Pg) then
      Result := FmtMessage(CustomMessage('ErrPortBusy'), [IntToStr(Pg)]);
  end;
end;

{ --- Procedura guidata --- }

procedure AddLang(const Code, Caption: String);
var
  N: Integer;
begin
  N := GetArrayLength(LangCodes);
  SetArrayLength(LangCodes, N + 1);
  LangCodes[N] := Code;
  LangPage.Add(Caption + ' (' + Code + ')');
end;

procedure InitializeWizard;
var
  Lang: String;
  I: Integer;
begin
  PortsPage := CreateInputQueryPage(wpSelectDir, CustomMessage('PortsCaption'),
    CustomMessage('PortsDescription'), CustomMessage('PortsSubCaption'));
  PortsPage.Add(CustomMessage('HttpPortLabel'), False);
  PortsPage.Add(CustomMessage('PgPortLabel'), False);
  PortsPage.Values[0] := ExpandConstant('{param:HTTPPORT|' + GetPreviousData('HttpPort', '3000') + '}');
  PortsPage.Values[1] := ExpandConstant('{param:PGPORT|' + GetPreviousData('PgPort', '5432') + '}');

  LangPage := CreateInputOptionPage(PortsPage.ID, CustomMessage('LangCaption'),
    CustomMessage('LangDescription'), CustomMessage('LangSubCaption'), True, True);
  AddLang('it', 'Italiano');
  AddLang('en', 'English');
  AddLang('de', 'Deutsch');
  AddLang('fr', 'Francais');
  AddLang('es', 'Espanol');
  AddLang('pt-BR', 'Portugues (Brasil)');
  AddLang('nl', 'Nederlands');
  AddLang('pl', 'Polski');
  AddLang('ru', 'Russkij');
  AddLang('ja', 'Japanese');
  AddLang('zh', 'Chinese (simplified)');

  { Default: parametro /REDMINELANG, poi installazione precedente, poi lingua del setup }
  Lang := ExpandConstant('{param:REDMINELANG|' + GetPreviousData('RedmineLang', ActiveLanguage) + '}');
  LangPage.SelectedValueIndex := 1;
  for I := 0 to GetArrayLength(LangCodes) - 1 do
    if CompareText(LangCodes[I], Lang) = 0 then
      LangPage.SelectedValueIndex := I;

  ConfigExitCode := -1;
end;

procedure RegisterPreviousData(PreviousDataKey: Integer);
begin
  SetPreviousData(PreviousDataKey, 'HttpPort', GetHttpPort(''));
  SetPreviousData(PreviousDataKey, 'PgPort', GetPgPort);
  SetPreviousData(PreviousDataKey, 'RedmineLang', GetRedmineLang);
end;

function NextButtonClick(CurPageID: Integer): Boolean;
var
  Error: String;
begin
  Result := True;
  if (CurPageID = wpSelectDir) and not ValidPath(WizardDirValue) then begin
    MsgBox(CustomMessage('ErrPath'), mbError, MB_OK);
    Result := False;
  end else if CurPageID = PortsPage.ID then begin
    Error := CheckPorts;
    if Error <> '' then begin
      MsgBox(Error, mbError, MB_OK);
      Result := False;
    end;
  end;
end;

{ --- Installazione --- }

function PrepareToInstall(var NeedsRestart: Boolean): String;
begin
  { In modalita' silenziosa le pagine non vengono mostrate: le validazioni si ripetono qui }
  if not ValidPath(WizardDirValue) then begin
    Result := CustomMessage('ErrPath');
    Exit;
  end;
  Result := CheckPorts;
  if Result <> '' then
    Exit;
  { Prima di copiare qualsiasi file: se il runtime non si installa, il setup si ferma pulito }
  Result := EnsureVcRuntime;
  if Result <> '' then
    Exit;
  { Aggiornamento/reinstallazione: i servizi tengono aperti i file da sostituire }
  if ServiceInstalled(RedmineService) or ServiceInstalled(PgService) then
    RunPowerShell('Stop-Service ' + RedmineService + ',' + PgService + ' -Force -ErrorAction SilentlyContinue');
end;

procedure CurStepChanged(CurStep: TSetupStep);
var
  Params, LogFile: String;
begin
  if CurStep <> ssPostInstall then
    Exit;

  LogFile := ExpandConstant('{app}\logs\setup.log');
  Params := '-NoProfile -ExecutionPolicy Bypass -File ' + AddQuotes(ExpandConstant('{app}\setup\Install-Redmine.ps1')) +
            ' -Offline -InstallDir ' + AddQuotes(ExpandConstant('{app}')) +
            ' -HttpPort ' + GetHttpPort('') + ' -PgPort ' + GetPgPort +
            ' -Language ' + GetRedmineLang + ' -LogFile ' + AddQuotes(LogFile);
  if WizardIsTaskSelected('firewall') then
    Params := Params + ' -OpenFirewall';

  WizardForm.StatusLabel.Caption := CustomMessage('Configuring');
  WizardForm.FilenameLabel.Caption := '';
  WizardForm.ProgressGauge.Style := npbstMarquee;
  Log('Configurazione: powershell.exe ' + Params);
  try
    if not Exec(PowerShellExe, Params, ExpandConstant('{app}'), SW_HIDE, ewWaitUntilTerminated, ConfigExitCode) then
      ConfigExitCode := -1;
  finally
    WizardForm.ProgressGauge.Style := npbstNormal;
  end;
  Log('Configurazione terminata con codice ' + IntToStr(ConfigExitCode));

  if ConfigExitCode <> 0 then
    SuppressibleMsgBox(FmtMessage(CustomMessage('ConfigFailed'), [IntToStr(ConfigExitCode), LogFile]),
      mbCriticalError, MB_OK, IDOK);
end;

{ Exit code del setup: 0 solo se anche la configurazione e' riuscita (utile per /VERYSILENT) }
function GetCustomSetupExitCode: Integer;
begin
  if ConfigExitCode <> 0 then
    Result := 1
  else
    Result := 0;
end;

{ --- Disinstallazione --- }

procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
var
  AppDir: String;
begin
  if CurUninstallStep <> usPostUninstall then
    Exit;
  AppDir := ExpandConstant('{app}');
  if not DirExists(AppDir) then
    Exit;
  if HasParam('/REMOVEDATA') or
     (not UninstallSilent and
      (MsgBox(FmtMessage(CustomMessage('RemoveData'), [AppDir]), mbConfirmation, MB_YESNO or MB_DEFBUTTON2) = IDYES)) then
    DelTree(AppDir, True, True, True)
  else if not UninstallSilent then
    MsgBox(FmtMessage(CustomMessage('DataKept'), [AppDir]), mbInformation, MB_OK);
end;
