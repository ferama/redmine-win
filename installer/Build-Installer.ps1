#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Costruisce l'installer offline di Redmine (installer\dist\Redmine-<versione>-Setup.exe).

.DESCRIPTION
    1. Installazione reale di build in -BuildDir con Install-Redmine.ps1 (servizi e porte dedicati, per non
       interferire con un Redmine installato): scarica i componenti e compila le gem native con MSYS2.
    2. Rimuove i servizi di build e prepara installer\stage con i soli file da distribuire:
       niente MSYS2, cache/documentazione delle gem, pgAdmin/StackBuilder, database, credenziali,
       secret_token, database.yml, log e file temporanei.
    3. Compila installer\redmine-setup.iss con ISCC (Inno Setup portable in installer\tools\InnoSetup).
    I download vengono conservati in installer\cache\downloads e riusati dalle build successive.
#>
[CmdletBinding()]
param(
    [string]$BuildDir = 'C:\RedmineBuild',
    [switch]$KeepBuildDir,
    # Riusa l'installazione di build esistente in BuildDir (rifa' solo stage e compilazione)
    [switch]$ReuseBuild,
    # Scaricato in installer\tools\InnoSetup (installazione portable, per utente) se manca
    [string]$InnoSetupVersion = '7.1.0',
    # Runtime Visual C++ 2015-2022+ x64 (richiesto da PostgreSQL), incluso nell'installer.
    # Viene riscaricato a ogni build per includere sempre l'ultima versione con le correzioni di sicurezza
    [string]$VcRedistUrl = 'https://aka.ms/vs/18/release/vc_redist.x64.exe'
)
$ErrorActionPreference = 'Stop'
$InstallerDir = $PSScriptRoot
$ProjectDir   = Split-Path $InstallerDir
$Stage        = Join-Path $InstallerDir 'stage'
$Cache        = Join-Path $InstallerDir 'cache\downloads'
$Iscc         = Join-Path $InstallerDir 'tools\InnoSetup\ISCC.exe'
$PgSvc        = 'RedmineBuildPG'
$RmSvc        = 'RedmineBuild'

function Write-Step([string]$Message) { Write-Host "`n### $Message" -ForegroundColor Magenta }
function Invoke-Robocopy([string]$From, [string]$To, [string[]]$Options) {
    robocopy $From $To /E /NFL /NDL /NJH /NP /R:1 /W:1 @Options | Out-Null
    if ($LASTEXITCODE -ge 8) { throw "robocopy $From -> $To fallito (exit $LASTEXITCODE)" }
}
function Remove-BuildServices {
    $wsw = Join-Path $BuildDir 'service\wsw.exe'
    if ((Get-Service $RmSvc -ErrorAction SilentlyContinue) -and (Test-Path $wsw)) { & $wsw uninstall --name $RmSvc | Out-Null }
    if (Get-Service $PgSvc -ErrorAction SilentlyContinue) {
        Stop-Service $PgSvc -Force -ErrorAction SilentlyContinue
        & (Join-Path $BuildDir 'pgsql\bin\pg_ctl.exe') unregister -N $PgSvc | Out-Null
    }
}

if (-not (Test-Path $Iscc)) {
    Write-Step "Inno Setup $InnoSetupVersion (portable)"
    $tag   = 'is-' + ($InnoSetupVersion -replace '\.', '_')
    $setup = Join-Path $InstallerDir "cache\innosetup-$InnoSetupVersion-x64.exe"
    New-Item -ItemType Directory -Force (Split-Path $setup) | Out-Null
    if (-not (Test-Path $setup)) {
        Invoke-WebRequest "https://github.com/jrsoftware/issrc/releases/download/$tag/innosetup-$InnoSetupVersion-x64.exe" -OutFile $setup -UseBasicParsing
    }
    if ((Get-AuthenticodeSignature $setup).Status -ne 'Valid') { throw "Firma digitale non valida: $setup" }
    $p = Start-Process $setup -Wait -PassThru -ArgumentList '/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', '/CURRENTUSER',
        '/PORTABLE=1', '/NOICONS', "/DIR=$(Split-Path $Iscc)"
    if ($p.ExitCode -ne 0 -or -not (Test-Path $Iscc)) { throw "Installazione di Inno Setup fallita (exit $($p.ExitCode))" }
}

# --- 1. Installazione di build ---------------------------------------------
if ($ReuseBuild -and (Test-Path (Join-Path $BuildDir 'redmine\Gemfile.lock'))) {
    Write-Step "Riuso dell'installazione di build in $BuildDir"
} else {
    Write-Step "Installazione di build in $BuildDir"
    Remove-BuildServices
    if (Test-Path $BuildDir) { Remove-Item $BuildDir -Recurse -Force }
    New-Item -ItemType Directory -Force (Join-Path $BuildDir 'downloads'), $Cache | Out-Null
    Copy-Item "$Cache\*" (Join-Path $BuildDir 'downloads') -ErrorAction SilentlyContinue

    & (Join-Path $ProjectDir 'Install-Redmine.ps1') -InstallDir $BuildDir -HttpPort 13000 -PgPort 15432 `
        -PgServiceName $PgSvc -RedmineServiceName $RmSvc -LogFile (Join-Path $InstallerDir 'build.log')
    Copy-Item (Join-Path $BuildDir 'downloads\*') $Cache -Force
}
$versions = @{}
Select-String -Path (Join-Path $ProjectDir 'Install-Redmine.ps1') -Pattern "^\s*\[string\]\`$(RedmineVersion)\s*=\s*'([^']+)'" |
    ForEach-Object { $versions[$_.Matches[0].Groups[1].Value] = $_.Matches[0].Groups[2].Value }
$AppVersion = $versions['RedmineVersion']

Write-Step 'Rimozione dei servizi di build'
Remove-BuildServices

# --- 2. Stage --------------------------------------------------------------
Write-Step "Preparazione di $Stage"
if (Test-Path $Stage) { Remove-Item $Stage -Recurse -Force }

$pg = Join-Path $BuildDir 'pgsql'
Invoke-Robocopy $pg (Join-Path $Stage 'pgsql') @('/XD', "$pg\pgAdmin 4", "$pg\StackBuilder", "$pg\doc", "$pg\include", "$pg\symbols")

$rb = Join-Path $BuildDir 'ruby'
$gemDirs = Get-ChildItem (Join-Path $rb 'lib\ruby\gems') -Directory | ForEach-Object { "$($_.FullName)\cache"; "$($_.FullName)\doc" }
Invoke-Robocopy $rb (Join-Path $Stage 'ruby') (@('/XD', "$rb\msys64", "$rb\share\doc", "$rb\share\ri") + $gemDirs +
    @('/XF', '*.o', 'mkmf.log', 'gem_make.out'))

$rm = Join-Path $BuildDir 'redmine'
Invoke-Robocopy $rm (Join-Path $Stage 'redmine') @('/XD', "$rm\files", "$rm\log", "$rm\tmp",
    '/XF', "$rm\config\database.yml", "$rm\config\initializers\secret_token.rb")
foreach ($d in 'files', 'log', 'tmp') { New-Item -ItemType Directory -Force (Join-Path $Stage "redmine\$d") | Out-Null }

New-Item -ItemType Directory -Force (Join-Path $Stage 'service'), (Join-Path $Stage 'setup') | Out-Null
Copy-Item (Join-Path $BuildDir 'service\wsw.exe') (Join-Path $Stage 'service')
Copy-Item (Join-Path $ProjectDir 'Install-Redmine.ps1'), (Join-Path $ProjectDir 'Uninstall-Redmine.ps1') (Join-Path $Stage 'setup')

# Nessun segreto o dato dell'installazione di build deve finire nel pacchetto
$leaks = @('config\database.yml', 'config\initializers\secret_token.rb' | ForEach-Object { Join-Path $Stage "redmine\$_" } |
             Where-Object { Test-Path $_ } | Get-Item) +
         @(Get-ChildItem (Join-Path $Stage 'redmine\log'), (Join-Path $Stage 'redmine\files') -Recurse -File) +
         @(Get-ChildItem $Stage -Recurse -File -Include 'credentials.txt', 'PG_VERSION', 'postgresql.conf' |
             Where-Object { $_.FullName -notmatch '\\pgsql\\share\\' })
if ($leaks) { throw "File da non distribuire nello stage: $($leaks.FullName -join ', ')" }
if (Test-Path (Join-Path $Stage 'ruby\msys64')) { throw 'MSYS2 non deve far parte dello stage' }

$files = Get-ChildItem $Stage -Recurse -File
Write-Host ("    stage: {0:N0} file, {1:N0} MB" -f $files.Count, (($files | Measure-Object Length -Sum).Sum / 1MB))
foreach ($top in Get-ChildItem $Stage -Directory) {
    $sz = (Get-ChildItem $top.FullName -Recurse -File | Measure-Object Length -Sum).Sum / 1MB
    Write-Host ("      {0,-10} {1,8:N0} MB" -f $top.Name, $sz)
}

if (-not $KeepBuildDir) {
    Write-Step "Rimozione di $BuildDir"
    Remove-Item $BuildDir -Recurse -Force
}

# --- 3. Runtime Visual C++ -------------------------------------------------
Write-Step 'Runtime Visual C++ x64'
$vcRedist = Join-Path $InstallerDir 'cache\vc_redist.x64.exe'
Invoke-WebRequest $VcRedistUrl -OutFile "$vcRedist.part" -UseBasicParsing
$sig = Get-AuthenticodeSignature "$vcRedist.part"
if ($sig.Status -ne 'Valid' -or $sig.SignerCertificate.Subject -notmatch '^CN=Microsoft Corporation,') {
    throw "vc_redist.x64.exe: firma non valida ($($sig.Status), $($sig.SignerCertificate.Subject))"
}
Move-Item "$vcRedist.part" $vcRedist -Force
$vcVersion = [version](Get-Item $vcRedist).VersionInfo.FileVersion
Write-Host "    vc_redist.x64.exe $vcVersion"

# --- 4. Compilazione -------------------------------------------------------
Write-Step "Compilazione installer Redmine $AppVersion"
Push-Location $InstallerDir
try {
    & $Iscc /Qp "/DAppVersion=$AppVersion" "/DStageDir=$Stage" "/DVcRedist=$vcRedist" `
        "/DVcRedistVersion=$vcVersion" "/DVcRedistMinor=$($vcVersion.Minor)" "/DVcRedistBld=$($vcVersion.Build)" 'redmine-setup.iss'
    if ($LASTEXITCODE -ne 0) { throw "ISCC fallito (exit $LASTEXITCODE)" }
} finally {
    Pop-Location
}
$out = Get-Item (Join-Path $InstallerDir "dist\Redmine-$AppVersion-Setup.exe")
Write-Host ("`nInstaller: {0} ({1:N0} MB)" -f $out.FullName, ($out.Length / 1MB)) -ForegroundColor Green
'BUILD_DONE'
