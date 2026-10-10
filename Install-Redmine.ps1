#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Installa Redmine + MariaDB in modalita' "portable" (tutto sotto una cartella) e li registra come servizi Windows.

.DESCRIPTION
    Struttura risultante (default C:\Redmine):
        downloads\     archivi scaricati (cache, riusati se si rilancia lo script)
        mariadb\       binari MariaDB (zip ufficiale)    -> servizio "RedmineMariaDB" (mariadb-install-db)
        mariadb-data\  dati e my.ini di MariaDB
        ruby\          Ruby (RubyInstaller 7z) + msys64\ (DevKit MSYS2 portable, per compilare le gem native)
        redmine\       applicazione Redmine, servita da Puma -> servizio "Redmine" (wsw)
        service\       wsw.exe (service wrapper; configurazione nel registro, vedi "wsw status -v -n Redmine")
        logs\          log del servizio Redmine (output di Puma + eventi di wsw)
        credentials.txt  password generate (leggibile solo dagli Administrators)

    Entrambi i servizi girano come NT AUTHORITY\NetworkService. MariaDB ascolta solo su 127.0.0.1.
    Nota: Redmine 7.0 dichiara il supporto per MySQL 8.0-8.4; MariaDB e' compatibile via adapter mysql2
    ma non e' tra i database testati ufficialmente.
    Lo script e' rilanciabile: gli step gia' completati vengono saltati.

.EXAMPLE
    .\Install-Redmine.ps1
    .\Install-Redmine.ps1 -InstallDir D:\Redmine -HttpPort 8080 -DbPort 3307 -OpenFirewall
#>
[CmdletBinding()]
param(
    [string]$InstallDir      = 'C:\Redmine',
    [string]$RedmineVersion  = '7.0.2',
    # Redmine 7.0 supporta Ruby 3.2-4.0; 3.4 ha la miglior copertura di gem native precompilate per Windows
    [string]$RubyVersion     = '3.4.11-1',
    # MariaDB LTS (https://mariadb.org/download): aggiornare versione e SHA256 insieme
    [string]$MariaDBVersion  = '11.8.9',
    [string]$MariaDBSha256   = '830c46727d9278eae212ae3eca44eeb9e71b2a68704e95f344a64fba7b1963f5',
    [string]$MariaDBZipUrl   = "https://downloads.mariadb.org/rest-api/mariadb/$MariaDBVersion/mariadb-$MariaDBVersion-winx64.zip",
    # Tag della release di https://github.com/ferama/wsw (service wrapper)
    [string]$WswVersion      = '0.10.0',
    [int]$DbPort             = 3306,
    [int]$HttpPort           = 3000,
    [string]$Language        = 'it',
    [string]$DbServiceName      = 'RedmineMariaDB',
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
$DbDir       = Join-Path $InstallDir 'mariadb'
$DbData      = Join-Path $InstallDir 'mariadb-data'
$RubyDir     = Join-Path $InstallDir 'ruby'
$RedmineDir  = Join-Path $InstallDir 'redmine'
$ServiceDir  = Join-Path $InstallDir 'service'
$LogDir      = Join-Path $InstallDir 'logs'
$CredFile    = Join-Path $InstallDir 'credentials.txt'
$ServiceUser = 'NT AUTHORITY\NetworkService'

$RubyExe   = Join-Path $RubyDir 'bin\ruby.exe'
$BundleRb  = Join-Path $RubyDir 'bin\bundle'
$MariaDb   = Join-Path $DbDir 'bin\mariadb.exe'
$MyIni     = Join-Path $DbData 'my.ini'

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
    # che Ruby/YAML e MariaDB non accettano in Gemfile.local, database.yml e my.ini
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

function Invoke-MariaDbRoot([string]$Sql) {
    # Password via MYSQL_PWD: non compare nella riga di comando del processo
    $env:MYSQL_PWD = $creds['DB_ROOT_PASSWORD']
    try {
        Invoke-Native $MariaDb --protocol=TCP -h 127.0.0.1 -P $DbPort -u root --batch -e $Sql
    } finally {
        Remove-Item Env:MYSQL_PWD -ErrorAction SilentlyContinue
    }
}

function Copy-NativeGemDlls {
    # Le gem native compilate con MSYS2 (es. mysql2 -> libmariadb.dll) dipendono da DLL di msys64\ucrt64\bin.
    # Le copiamo in ruby\bin (cartella dell'eseguibile, sempre nel percorso di ricerca delle DLL)
    # cosi' Ruby funziona anche senza MSYS2, come nell'installer offline.
    $ucrtBin = Join-Path $MsysDir 'ucrt64\bin'
    $objdump = Join-Path $ucrtBin 'objdump.exe'
    $target  = Join-Path $RubyDir 'bin'
    $present = @{}
    Get-ChildItem $target, (Join-Path $target 'ruby_builtin_dlls') -Filter *.dll -ErrorAction SilentlyContinue |
        ForEach-Object { $present[$_.Name.ToLower()] = $true }
    $queue = New-Object System.Collections.Generic.Queue[string]
    Get-ChildItem (Join-Path $RubyDir 'lib\ruby\gems') -Recurse -Filter *.so | ForEach-Object { $queue.Enqueue($_.FullName) }
    $seen = @{}
    while ($queue.Count -gt 0) {
        $file = $queue.Dequeue()
        $deps = & $objdump -p $file | Select-String 'DLL Name:\s*(\S+)' | ForEach-Object { $_.Matches[0].Groups[1].Value }
        foreach ($dll in $deps) {
            $key = $dll.ToLower()
            if ($seen[$key] -or $present[$key]) { continue }
            $seen[$key] = $true
            $source = Join-Path $ucrtBin $dll
            if (Test-Path $source) {
                Copy-Item $source $target
                $present[$key] = $true
                Write-Host "    + $dll"
                $queue.Enqueue($source)
            }
        }
    }
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
if (-not $creds['DB_ROOT_PASSWORD'])    { $creds['DB_ROOT_PASSWORD']    = New-RandomPassword }
if (-not $creds['DB_REDMINE_PASSWORD']) { $creds['DB_REDMINE_PASSWORD'] = New-RandomPassword }
@(
    "# Credenziali generate da Install-Redmine.ps1 il $(Get-Date -Format s)"
    "DB_ENGINE = MariaDB $MariaDBVersion"
    "DB_ROOT_USER = root"
    "DB_ROOT_PASSWORD = $($creds['DB_ROOT_PASSWORD'])"
    "DB_REDMINE_USER = redmine"
    "DB_REDMINE_PASSWORD = $($creds['DB_REDMINE_PASSWORD'])"
    "DB_PORT = $DbPort"
    "REDMINE_URL = http://localhost:$HttpPort"
    "REDMINE_FIRST_LOGIN = admin / admin (cambio password obbligatorio al primo accesso)"
) | Set-Content -Path $CredFile -Encoding UTF8
# Accesso al file riservato ad Administrators e SYSTEM
Invoke-Native icacls.exe $CredFile /inheritance:r /grant:r '*S-1-5-32-544:F' '*S-1-5-18:F' | Out-Null

# --- 1. MariaDB ------------------------------------------------------------
Write-Step "MariaDB $MariaDBVersion"
if (-not (Test-Path (Join-Path $DbDir 'bin\mariadbd.exe'))) {
    $zip = Get-Download $MariaDBZipUrl "mariadb-$MariaDBVersion-winx64.zip"
    if ((Get-FileHash $zip -Algorithm SHA256).Hash -ne $MariaDBSha256) {
        Remove-Item $zip -Force
        throw "SHA256 di mariadb-$MariaDBVersion-winx64.zip non corrispondente: archivio rimosso, rilanciare lo script"
    }
    Expand-ArchiveTo $zip $InstallDir      # lo zip contiene la cartella "mariadb-<versione>-winx64"
    Rename-Item (Join-Path $InstallDir "mariadb-$MariaDBVersion-winx64") $DbDir
}

if (-not (Test-Path $MyIni)) {
    Write-Host "    mariadb-install-db in $DbData (servizio $DbServiceName)"
    if (Get-Service $DbServiceName -ErrorAction SilentlyContinue) {
        throw "Il servizio $DbServiceName esiste gia' ma $DbData no: rimuoverlo (sc.exe delete $DbServiceName) e rilanciare"
    }
    Invoke-Native (Join-Path $DbDir 'bin\mariadb-install-db.exe') "--datadir=$DbData" "--service=$DbServiceName" `
        "--port=$DbPort" "--password=$($creds['DB_ROOT_PASSWORD'])" --silent
    Add-Content -Path $MyIni -Encoding ASCII -Value @(
        ''
        '# --- Install-Redmine.ps1 ---'
        '[mysqld]'
        'bind-address=127.0.0.1'
        'character-set-server=utf8mb4'
        'collation-server=utf8mb4_unicode_ci'
        'transaction-isolation=READ-COMMITTED'
    )
} elseif (-not (Get-Service $DbServiceName -ErrorAction SilentlyContinue)) {
    # Dati conservati da una disinstallazione precedente: si registra solo il servizio
    Write-Host "    registrazione servizio $DbServiceName sui dati esistenti"
    Invoke-Native (Join-Path $DbDir 'bin\mariadbd.exe') --install $DbServiceName "--defaults-file=$MyIni"
}
# La porta segue sempre il parametro, anche quando i dati esistono gia'
$ini = [IO.File]::ReadAllText($MyIni)
$ini = [regex]::Replace($ini, '(?m)^\s*port\s*=\s*\d+\s*$', "port=$DbPort")
Write-TextFile $MyIni $ini

Grant-Modify $DbData $ServiceUser
Invoke-Native sc.exe config $DbServiceName obj= $ServiceUser password= '""' start= auto | Out-Null
Restart-Service $DbServiceName -Force -ErrorAction SilentlyContinue
Start-Service $DbServiceName

$env:MYSQL_PWD = $creds['DB_ROOT_PASSWORD']
$ready = $false
# In Windows PowerShell 5.1 lo stderr rediretto di un comando esterno diventa un errore che, con
# ErrorActionPreference = Stop, interromperebbe lo script mentre il server sta ancora partendo
$ErrorActionPreference = 'Continue'
for ($i = 0; $i -lt 60 -and -not $ready; $i++) {
    & (Join-Path $DbDir 'bin\mariadb-admin.exe') --protocol=TCP -h 127.0.0.1 -P $DbPort -u root --silent ping 2>$null | Out-Null
    $ready = ($LASTEXITCODE -eq 0)
    if (-not $ready) { Start-Sleep -Seconds 1 }
}
$ErrorActionPreference = 'Stop'
Remove-Item Env:MYSQL_PWD -ErrorAction SilentlyContinue
if (-not $ready) { throw "MariaDB non risponde sulla porta $DbPort" }

Write-Host "    creazione utente e database 'redmine'"
$pw = $creds['DB_REDMINE_PASSWORD']
Invoke-MariaDbRoot (@(
    "CREATE DATABASE IF NOT EXISTS redmine CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"
    # TCP da 127.0.0.1 puo' risultare come host 'localhost' o '127.0.0.1': l'utente esiste per entrambi
    foreach ($h in 'localhost', '127.0.0.1') {
        "CREATE USER IF NOT EXISTS 'redmine'@'$h' IDENTIFIED BY '$pw';"
        "ALTER USER 'redmine'@'$h' IDENTIFIED BY '$pw';"
        "GRANT ALL PRIVILEGES ON redmine.* TO 'redmine'@'$h';"
    }
    "FLUSH PRIVILEGES;"
) -join ' ')

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
if (-not $Offline) {
    if (-not (Test-Path (Join-Path $MsysDir 'ucrt64\bin\gcc.exe'))) {
        Write-Host "    ridk install 3 (toolchain MinGW UCRT64)"
        Invoke-Native (Join-Path $RubyDir 'bin\ridk.cmd') install 3
    }
    # Libreria client per la gem mysql2
    Invoke-Native (Join-Path $RubyDir 'bin\ridk.cmd') exec pacman -S --noconfirm --needed mingw-w64-ucrt-x86_64-libmariadbclient
}

$env:PATH       = "$RubyDir\bin;$DbDir\bin;$env:PATH"
$env:RAILS_ENV  = 'production'
$env:REDMINE_LANG = $Language

# --- 3. Redmine ------------------------------------------------------------
Write-Step "Redmine $RedmineVersion"
if (-not (Test-Path (Join-Path $RedmineDir 'config\application.rb'))) {
    $zip = Get-Download "https://www.redmine.org/releases/redmine-$RedmineVersion.zip" "redmine-$RedmineVersion.zip"
    Expand-ArchiveTo $zip $InstallDir
    Rename-Item (Join-Path $InstallDir "redmine-$RedmineVersion") $RedmineDir
}

# transaction_isolation READ-COMMITTED: richiesto da Redmine con MySQL/MariaDB
Write-TextFile (Join-Path $RedmineDir 'config\database.yml') @"
production:
  adapter: mysql2
  database: redmine
  host: 127.0.0.1
  port: $DbPort
  username: redmine
  password: "$($creds['DB_REDMINE_PASSWORD'])"
  encoding: utf8mb4
  variables:
    transaction_isolation: "READ-COMMITTED"

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
        Write-Host "    DLL native delle gem (per l'uso senza MSYS2)"
        Copy-NativeGemDlls
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
    --depends-on $DbServiceName --start-type delayed-auto `
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
