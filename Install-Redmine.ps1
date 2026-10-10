#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Installa Redmine + PostgreSQL in modalita' "portable" (tutto sotto una cartella) e li registra come servizi Windows.

.DESCRIPTION
    Struttura risultante (default C:\Redmine):
        downloads\   archivi scaricati (cache, riusati se si rilancia lo script)
        pgsql\       binari PostgreSQL (zip EDB)       -> servizio "RedminePostgreSQL" (pg_ctl register)
        pgdata\      cluster PostgreSQL
        ruby\        Ruby (RubyInstaller 7z) + msys64\ (DevKit MSYS2 portable, per compilare le gem native)
        redmine\     applicazione Redmine, servita da Puma -> servizio "Redmine" (wsw)
        service\     wsw.exe (service wrapper; configurazione nel registro, vedi "wsw status -v -n Redmine")
        logs\        log del servizio Redmine (output di Puma + eventi di wsw)
        credentials.txt  password generate (leggibile solo dagli Administrators)

    Entrambi i servizi girano come NT AUTHORITY\NetworkService.
    Lo script e' rilanciabile: gli step gia' completati vengono saltati.

.EXAMPLE
    .\Install-Redmine.ps1
    .\Install-Redmine.ps1 -InstallDir D:\Redmine -HttpPort 8080 -OpenFirewall
#>
[CmdletBinding()]
param(
    [string]$InstallDir      = 'C:\Redmine',
    [string]$RedmineVersion  = '7.0.2',
    # Redmine 7.0 supporta Ruby 3.2-4.0; 3.4 ha la miglior copertura di gem native precompilate per Windows

    [string]$RubyVersion     = '3.4.11-1',
    [string]$PostgresVersion = '17.11',
    # EDB pubblica gli zip tramite fileid: aggiornare insieme a PostgresVersion
    # (https://www.enterprisedb.com/download-postgresql-binaries)
    [string]$PostgresZipUrl  = 'https://sbp.enterprisedb.com/getfile.jsp?fileid=1260616',
    # Tag della release di https://github.com/ferama/wsw (service wrapper)
    [string]$WswVersion      = '0.10.0',
    [int]$PgPort             = 5432,
    [int]$HttpPort           = 3000,
    [string]$Language        = 'it',
    [string]$PgServiceName      = 'RedminePostgreSQL',
    [string]$RedmineServiceName = 'Redmine',
    [switch]$OpenFirewall,
    # Componenti gia' presenti in InstallDir (installer precompilato): niente download, MSYS2 ne' compilazione
    [switch]$Offline,
    # Se indicato, tutto l'output viene registrato anche in questo file
    [string]$LogFile
)

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'   # Invoke-WebRequest molto piu' veloce
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# --- Percorsi --------------------------------------------------------------
$DownloadDir = Join-Path $InstallDir 'downloads'
$PgDir       = Join-Path $InstallDir 'pgsql'
$PgData      = Join-Path $InstallDir 'pgdata'
$RubyDir     = Join-Path $InstallDir 'ruby'
$RedmineDir  = Join-Path $InstallDir 'redmine'
$ServiceDir  = Join-Path $InstallDir 'service'
$LogDir      = Join-Path $InstallDir 'logs'
$CredFile    = Join-Path $InstallDir 'credentials.txt'
$ServiceUser = 'NT AUTHORITY\NetworkService'

$RubyExe   = Join-Path $RubyDir 'bin\ruby.exe'
$BundleRb  = Join-Path $RubyDir 'bin\bundle'
$Psql      = Join-Path $PgDir 'bin\psql.exe'

# --- Helper ----------------------------------------------------------------
function Write-Step([string]$Message) {
    Write-Host "`n==> $Message" -ForegroundColor Cyan
}

function Invoke-Native {
    # Esegue un eseguibile e lancia un'eccezione se l'exit code non e' 0.
    # Volutamente senza param(): con un param block PowerShell interpreterebbe
    # argomenti come -E / -D / -U come propri parametri comuni.
    $filePath = $args[0]
    $rest     = @($args | Select-Object -Skip 1)   # sempre array, anche con un solo argomento
    & $filePath @rest
    if ($LASTEXITCODE -ne 0) { throw "Comando fallito (exit $LASTEXITCODE): $filePath $($rest -join ' ')" }
}

function Get-Download([string]$Url, [string]$FileName) {
    $target = Join-Path $DownloadDir $FileName
    if (Test-Path $target) {
        Write-Host "    gia' scaricato: $FileName"
    } elseif ($Offline) {
        throw "Modalita' offline: componente mancante ($FileName), il pacchetto di installazione e' incompleto"
    } else {
        Write-Host "    download: $Url"
        Invoke-WebRequest -Uri $Url -OutFile "$target.part" -UseBasicParsing
        Move-Item "$target.part" $target
    }
    return $target
}

function Expand-ArchiveTo([string]$Archive, [string]$Destination) {
    # tar.exe di Windows (libarchive) gestisce sia .zip sia .7z
    New-Item -ItemType Directory -Force $Destination | Out-Null
    Invoke-Native tar.exe -xf $Archive -C $Destination
}

function New-RandomPassword([int]$Length = 24) {
    # Solo alfanumerici: nessun problema di escaping in YAML / SQL / riga di comando
    # RNGCryptoServiceProvider: disponibile anche in Windows PowerShell 5.1 (.NET Framework)
    $chars = [char[]]'ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789'
    $rng   = New-Object Security.Cryptography.RNGCryptoServiceProvider
    $bytes = New-Object byte[] 4
    -join (1..$Length | ForEach-Object {
        $rng.GetBytes($bytes)
        $chars[[BitConverter]::ToUInt32($bytes, 0) % $chars.Length]
    })
}

function Write-TextFile([string]$Path, [string]$Text) {
    # UTF-8 senza BOM: in Windows PowerShell 5.1 Set-Content -Encoding UTF8 aggiunge il BOM,
    # che Ruby/YAML non accettano in Gemfile.local e database.yml
    [IO.File]::WriteAllText($Path, $Text, (New-Object Text.UTF8Encoding $false))
}

function Grant-Modify([string]$Path, [string]$Account) {
    Invoke-Native icacls.exe $Path /grant "${Account}:(OI)(CI)M" /T /Q | Out-Null
}

function Read-Credentials {
    $creds = @{}
    if (Test-Path $CredFile) {
        Get-Content $CredFile | Where-Object { $_ -match '^\s*([^=#]+?)\s*=\s*(.*)$' } |
            ForEach-Object { $creds[$Matches[1]] = $Matches[2] }
    }
    return $creds
}

if ($LogFile) {
    New-Item -ItemType Directory -Force (Split-Path $LogFile) | Out-Null
    Start-Transcript -Path $LogFile -Append | Out-Null
}
try {

# --- 0. Preparazione -------------------------------------------------------
Write-Step "Cartella di installazione: $InstallDir$(if ($Offline) { ' (offline)' })"
New-Item -ItemType Directory -Force $InstallDir, $DownloadDir, $ServiceDir, $LogDir | Out-Null

$creds = Read-Credentials
if (-not $creds['PG_SUPERUSER_PASSWORD']) { $creds['PG_SUPERUSER_PASSWORD'] = New-RandomPassword }
if (-not $creds['PG_REDMINE_PASSWORD'])   { $creds['PG_REDMINE_PASSWORD']   = New-RandomPassword }
@(
    "# Credenziali generate da Install-Redmine.ps1 il $(Get-Date -Format s)"
    "PG_SUPERUSER = postgres"
    "PG_SUPERUSER_PASSWORD = $($creds['PG_SUPERUSER_PASSWORD'])"
    "PG_REDMINE_USER = redmine"
    "PG_REDMINE_PASSWORD = $($creds['PG_REDMINE_PASSWORD'])"
    "PG_PORT = $PgPort"
    "REDMINE_URL = http://localhost:$HttpPort"
    "REDMINE_FIRST_LOGIN = admin / admin (cambio password obbligatorio al primo accesso)"
) | Set-Content -Path $CredFile -Encoding UTF8
# Accesso al file riservato ad Administrators e SYSTEM
Invoke-Native icacls.exe $CredFile /inheritance:r /grant:r '*S-1-5-32-544:F' '*S-1-5-18:F' | Out-Null

# --- 1. PostgreSQL ---------------------------------------------------------
Write-Step "PostgreSQL $PostgresVersion"
if (-not (Test-Path (Join-Path $PgDir 'bin\postgres.exe'))) {
    $zip = Get-Download $PostgresZipUrl "postgresql-$PostgresVersion-windows-x64-binaries.zip"
    Expand-ArchiveTo $zip $InstallDir      # lo zip contiene la cartella "pgsql"
}

if (-not (Test-Path (Join-Path $PgData 'PG_VERSION'))) {
    Write-Host "    initdb in $PgData"
    $pwFile = Join-Path $env:TEMP "pgpw-$([guid]::NewGuid()).txt"
    try {
        Set-Content -Path $pwFile -Value $creds['PG_SUPERUSER_PASSWORD'] -NoNewline -Encoding ASCII
        Invoke-Native (Join-Path $PgDir 'bin\initdb.exe') -D $PgData -U postgres "--pwfile=$pwFile" `
            -A scram-sha-256 -E UTF8 --locale=C
    } finally {
        Remove-Item $pwFile -Force -ErrorAction SilentlyContinue
    }
    Add-Content -Path (Join-Path $PgData 'postgresql.conf') -Value @(
        ''
        '# --- Install-Redmine.ps1 ---'
        "port = $PgPort"
        "listen_addresses = 'localhost'"
    )
}
Grant-Modify $PgData $ServiceUser

if (-not (Get-Service $PgServiceName -ErrorAction SilentlyContinue)) {
    Write-Host "    registrazione servizio $PgServiceName"
    Invoke-Native (Join-Path $PgDir 'bin\pg_ctl.exe') register -N $PgServiceName -U $ServiceUser `
        -D $PgData -S auto -w
}
Start-Service $PgServiceName

$env:PGPASSWORD = $creds['PG_SUPERUSER_PASSWORD']
$ready = $false
for ($i = 0; $i -lt 30 -and -not $ready; $i++) {
    & (Join-Path $PgDir 'bin\pg_isready.exe') -h localhost -p $PgPort -q
    $ready = ($LASTEXITCODE -eq 0)
    if (-not $ready) { Start-Sleep -Seconds 1 }
}
if (-not $ready) { throw "PostgreSQL non risponde sulla porta $PgPort" }

Write-Host "    creazione ruolo e database 'redmine'"
$pgArgs = @('-h', 'localhost', '-p', $PgPort, '-U', 'postgres', '-v', 'ON_ERROR_STOP=1', '-tAq')
$roleExists = (& $Psql @pgArgs -c "SELECT 1 FROM pg_roles WHERE rolname='redmine'") -eq '1'
if ($roleExists) {
    Invoke-Native $Psql @pgArgs -c "ALTER ROLE redmine WITH LOGIN PASSWORD '$($creds['PG_REDMINE_PASSWORD'])'"
} else {
    Invoke-Native $Psql @pgArgs -c "CREATE ROLE redmine LOGIN PASSWORD '$($creds['PG_REDMINE_PASSWORD'])' NOINHERIT VALID UNTIL 'infinity'"
}
$dbExists = (& $Psql @pgArgs -c "SELECT 1 FROM pg_database WHERE datname='redmine'") -eq '1'
if (-not $dbExists) {
    Invoke-Native $Psql @pgArgs -c "CREATE DATABASE redmine WITH ENCODING='UTF8' OWNER=redmine TEMPLATE=template0"
}
Remove-Item Env:PGPASSWORD

# --- 2. Ruby + DevKit (MSYS2) portable -------------------------------------
Write-Step "Ruby $RubyVersion"
if (-not (Test-Path $RubyExe)) {
    $archive = Get-Download "https://github.com/oneclick/rubyinstaller2/releases/download/RubyInstaller-$RubyVersion/rubyinstaller-$RubyVersion-x64.7z" `
        "rubyinstaller-$RubyVersion-x64.7z"
    Expand-ArchiveTo $archive $InstallDir
    Rename-Item (Join-Path $InstallDir "rubyinstaller-$RubyVersion-x64") $RubyDir
}

# MSYS2 dentro ruby\msys64: RubyInstaller lo trova automaticamente li'
$MsysDir = Join-Path $RubyDir 'msys64'
if ($Offline) {
    Write-Host "    gem native precompilate: MSYS2 non necessario"
} elseif (-not (Test-Path (Join-Path $MsysDir 'usr\bin\bash.exe'))) {
    Write-Step "MSYS2 (DevKit per compilare le gem native)"
    $sfx = Get-Download 'https://repo.msys2.org/distrib/msys2-x86_64-latest.sfx.exe' 'msys2-x86_64-latest.sfx.exe'
    Invoke-Native $sfx -y "-o$RubyDir"
    # Primo avvio: inizializza keyring pacman
    Invoke-Native (Join-Path $MsysDir 'usr\bin\bash.exe') -lc 'true'
}
if (-not $Offline -and -not (Test-Path (Join-Path $MsysDir 'ucrt64\bin\gcc.exe'))) {
    Write-Host "    ridk install 3 (toolchain MinGW UCRT64)"
    Invoke-Native (Join-Path $RubyDir 'bin\ridk.cmd') install 3
}

$env:PATH       = "$RubyDir\bin;$PgDir\bin;$env:PATH"
$env:RAILS_ENV  = 'production'
$env:REDMINE_LANG = $Language

# --- 3. Redmine ------------------------------------------------------------
Write-Step "Redmine $RedmineVersion"
if (-not (Test-Path (Join-Path $RedmineDir 'config\application.rb'))) {
    $zip = Get-Download "https://www.redmine.org/releases/redmine-$RedmineVersion.zip" "redmine-$RedmineVersion.zip"
    Expand-ArchiveTo $zip $InstallDir
    Rename-Item (Join-Path $InstallDir "redmine-$RedmineVersion") $RedmineDir
}

Write-TextFile (Join-Path $RedmineDir 'config\database.yml') @"
production:
  adapter: postgresql
  database: redmine
  host: localhost
  port: $PgPort
  username: redmine
  password: "$($creds['PG_REDMINE_PASSWORD'])"
  encoding: utf8

"@

# Puma come application server (Gemfile.local e' il punto di estensione previsto da Redmine)
Write-TextFile (Join-Path $RedmineDir 'Gemfile.local') "gem 'puma'`n"

foreach ($d in 'files', 'log', 'tmp', 'tmp\pdf', 'public\assets') {
    New-Item -ItemType Directory -Force (Join-Path $RedmineDir $d) | Out-Null
}

Push-Location $RedmineDir
try {
    Invoke-Native $RubyExe $BundleRb config set --local without 'development test'
    if ($Offline) {
        Write-Host "    bundle check (gem precompilate)"
        Invoke-Native $RubyExe $BundleRb check
    } else {
        Write-Host "    bundle install"
        Invoke-Native $RubyExe $BundleRb install
    }

    if (-not (Test-Path 'config\initializers\secret_token.rb')) {
        Invoke-Native $RubyExe $BundleRb exec rake generate_secret_token
    }
    Write-Host "    migrazione database"
    Invoke-Native $RubyExe $BundleRb exec rake db:migrate
    Write-Host "    dati di default ($Language)"
    Invoke-Native $RubyExe $BundleRb exec rake redmine:load_default_data

    # Redmine 7.0.x: la migrazione 001_setup crea l'admin con mail_notification = true, che il modello
    # attuale rifiuta; usando save (non save!) l'utente non viene creato e nessuno se ne accorge.
    # Se non esiste alcun amministratore lo creiamo noi: admin/admin con cambio password al primo accesso.
    $ensureAdmin = Join-Path $env:TEMP "redmine-ensure-admin-$([guid]::NewGuid()).rb"
    Write-TextFile $ensureAdmin @'
if User.where(admin: true).exists?
  puts "    amministratore presente: #{User.where(admin: true).pluck(:login).join(', ')}"
else
  user = User.new(firstname: 'Redmine', lastname: 'Admin', mail: 'admin@example.net')
  user.login = 'admin'
  user.admin = true
  user.salt_password('admin')
  user.must_change_passwd = true
  user.save!
  puts "    creato l'utente admin (password admin, da cambiare al primo accesso)"
end
'@
    try {
        Invoke-Native $RubyExe $BundleRb exec rails runner $ensureAdmin
    } finally {
        Remove-Item $ensureAdmin -Force -ErrorAction SilentlyContinue
    }
    Write-Host "    precompilazione asset"
    Invoke-Native $RubyExe $BundleRb exec rake assets:precompile
} finally {
    Pop-Location
}
# --- 4. Servizio Redmine (wsw) ---------------------------------------------
Write-Step "Servizio $RedmineServiceName (wsw $WswVersion)"
$Wsw = Join-Path $ServiceDir 'wsw.exe'
if (-not ($Offline -and (Test-Path $Wsw))) {
    $wswZip  = Get-Download "https://github.com/ferama/wsw/releases/download/$WswVersion/wsw-x86_64.zip" "wsw-$WswVersion-x86_64.zip"
    $wswHash = Get-Download "https://github.com/ferama/wsw/releases/download/$WswVersion/wsw-x86_64.zip.sha256" "wsw-$WswVersion-x86_64.zip.sha256"
    $expected = ((Get-Content $wswHash -Raw).Trim() -split '\s+')[0]
    if ((Get-FileHash $wswZip -Algorithm SHA256).Hash -ne $expected) {
        Remove-Item $wswZip, $wswHash -Force
        throw "SHA256 di wsw-$WswVersion-x86_64.zip non corrispondente: archivio rimosso, rilanciare lo script"
    }
}

# Il servizio viene sempre ricreato, cosi' la configurazione corrisponde ai parametri dello script
# (vale anche per la migrazione da una vecchia installazione basata su WinSW)
if (Get-Service $RedmineServiceName -ErrorAction SilentlyContinue) {
    Write-Host "    rimozione del servizio esistente"
    Stop-Service $RedmineServiceName -Force -ErrorAction SilentlyContinue
    Invoke-Native sc.exe delete $RedmineServiceName | Out-Null
    for ($i = 0; $i -lt 30 -and (Get-Service $RedmineServiceName -ErrorAction SilentlyContinue); $i++) { Start-Sleep 1 }
    if (Get-Service $RedmineServiceName -ErrorAction SilentlyContinue) {
        throw "Il servizio $RedmineServiceName e' ancora marcato per l'eliminazione: chiudere services.msc e rilanciare"
    }
}
# Residui di WinSW
Remove-Item (Join-Path $ServiceDir "$RedmineServiceName.exe"), (Join-Path $ServiceDir "$RedmineServiceName.xml") -ErrorAction SilentlyContinue
Remove-Item (Join-Path $LogDir "$RedmineServiceName.*.log") -ErrorAction SilentlyContinue

if ($wswZip) { Expand-ArchiveTo $wswZip $ServiceDir }

Invoke-Native $Wsw install --name $RedmineServiceName `
    --display-name $RedmineServiceName --description "Redmine $RedmineVersion (Puma su porta $HttpPort)" `
    --exe $RubyExe --working-dir $RedmineDir `
    --env RAILS_ENV=production --env "PATH=$RubyDir\bin;%PATH%" --env "BUNDLE_USER_HOME=$RedmineDir\tmp\bundle" `
    --depends-on $PgServiceName --start-type delayed-auto `
    --account-name $ServiceUser --grant-dir $RedmineDir `
    --restart always --restart-delay 10 --restart-max-delay 120 --stop-timeout 20 `
    --log-dir $LogDir --log-max-size 10 --max-log-files 8 `
    '--' $BundleRb exec puma --environment production --bind "tcp://0.0.0.0:$HttpPort" --threads 2:8 config.ru

if ($OpenFirewall) {
    Write-Step "Regola firewall TCP $HttpPort"
    if (-not (Get-NetFirewallRule -DisplayName 'Redmine HTTP' -ErrorAction SilentlyContinue)) {
        New-NetFirewallRule -DisplayName 'Redmine HTTP' -Direction Inbound -Protocol TCP -LocalPort $HttpPort -Action Allow | Out-Null
    }
}

# --- 5. Verifica -----------------------------------------------------------
Write-Step "Attendo che Redmine risponda su http://localhost:$HttpPort ..."
$ok = $false
for ($i = 0; $i -lt 60 -and -not $ok; $i++) {
    try {
        $ok = (Invoke-WebRequest "http://localhost:$HttpPort/login" -UseBasicParsing -TimeoutSec 5).StatusCode -eq 200
    } catch { Start-Sleep -Seconds 2 }
}
if ($ok) {
    Write-Host "`nRedmine e' attivo: http://localhost:$HttpPort  (login admin/admin)" -ForegroundColor Green
} else {
    Write-Warning "Redmine non risponde ancora: controlla $LogDir e $RedmineDir\log\production.log"
}
Write-Host "Credenziali salvate in $CredFile"

} finally {
    if ($LogFile) { Stop-Transcript | Out-Null }
}
