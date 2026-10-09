#Requires -RunAsAdministrator
<#
    Test end-to-end dell'installer offline:
    installazione silenziosa con parametri -> Test-RedmineService.ps1 -> disinstallazione che conserva i dati ->
    reinstallazione sugli stessi dati -> disinstallazione con /REMOVEDATA.
#>
param(
    [string]$Setup      = (Get-ChildItem (Join-Path $PSScriptRoot 'dist\Redmine-*-Setup.exe') | Sort-Object LastWriteTime | Select-Object -Last 1).FullName,
    [string]$InstallDir = 'C:\RedmineSetupTest',
    [int]$HttpPort      = 8081,
    [int]$PgPort        = 5433
)
$ErrorActionPreference = 'Continue'
$results = [System.Collections.Generic.List[object]]::new()
function Check([string]$Name, [bool]$Ok, [string]$Detail = '') {
    $esito = if ($Ok) { 'PASS' } else { 'FAIL' }
    $results.Add([pscustomobject]@{ Test = $Name; Esito = $esito; Dettaglio = $Detail })
    Write-Host ("[{0}] {1}  {2}" -f $esito, $Name, $Detail) -ForegroundColor ($(if ($Ok) { 'Green' } else { 'Red' }))
}
function Section([string]$Title) { Write-Host "`n==> $Title" -ForegroundColor Cyan }
function Run([string]$Exe, [string[]]$ArgList) {
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $p = Start-Process $Exe -ArgumentList $ArgList -Wait -PassThru
    [pscustomobject]@{ Code = $p.ExitCode; Sec = [math]::Round($sw.Elapsed.TotalSeconds) }
}
function Install { Run $Setup @('/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', "/DIR=$InstallDir", "/HTTPPORT=$HttpPort",
                                 "/PGPORT=$PgPort", '/REDMINELANG=en', '/TASKS=firewall', "/LOG=$InstallDir-setup.log") }
function Uninstall([string[]]$Extra = @()) { Run (Join-Path $InstallDir 'unins000.exe') (@('/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART') + $Extra) }
function Psql([string]$Sql) {
    $c = @{}; Get-Content (Join-Path $InstallDir 'credentials.txt') | Where-Object { $_ -match '^\s*([^=#]+?)\s*=\s*(.*)$' } | ForEach-Object { $c[$Matches[1]] = $Matches[2] }
    $env:PGPASSWORD = $c['PG_SUPERUSER_PASSWORD']
    $out = & (Join-Path $InstallDir 'pgsql\bin\psql.exe') -h localhost -p $PgPort -U postgres -d redmine -tAq -c $Sql 2>&1
    Remove-Item Env:PGPASSWORD
    ($out | Out-String).Trim()
}
function NoServices { -not (Get-Service Redmine, RedminePostgreSQL -ErrorAction SilentlyContinue) }

Write-Host "Installer: $Setup ($([math]::Round((Get-Item $Setup).Length / 1MB)) MB)"
if (-not (NoServices)) { throw 'Servizi Redmine gia'' presenti: il test richiede una macchina senza Redmine installato' }

Section 'Installazione silenziosa'
$r = Install
Check 'setup: exit code 0' ($r.Code -eq 0) "exit=$($r.Code) in $($r.Sec) s"
Check 'MSYS2 non installato' (-not (Test-Path (Join-Path $InstallDir 'ruby\msys64'))) ''
Check 'PostgreSQL in ascolto sulla porta scelta' ([bool](Get-NetTCPConnection -State Listen -LocalPort $PgPort -ErrorAction SilentlyContinue)) "porta $PgPort"
Check 'regola firewall creata' ([bool](Get-NetFirewallRule -DisplayName 'Redmine HTTP' -ErrorAction SilentlyContinue)) ''
Check 'dati iniziali in inglese' ((Psql "select name from trackers order by position limit 1") -eq 'Bug') (Psql "select string_agg(name, ', ' order by position) from trackers")
Check 'secret_token generato all''installazione' (Test-Path (Join-Path $InstallDir 'redmine\config\initializers\secret_token.rb')) ''
Check 'collegamento nel menu Start' (Test-Path "$env:ProgramData\Microsoft\Windows\Start Menu\Programs\Redmine.lnk") ''

Section 'Test del servizio'
# Test-RedmineService stampa un proprio riepilogo ("Totale: ...") ed esce con 1 se qualche controllo fallisce
& (Join-Path (Split-Path $PSScriptRoot) 'Test-RedmineService.ps1') -InstallDir $InstallDir -HttpPort $HttpPort
Check 'Test-RedmineService.ps1 senza FAIL' ($LASTEXITCODE -eq 0) "exit=$LASTEXITCODE"

Section 'Disinstallazione che conserva i dati'
Psql 'create table install_marker (id int); insert into install_marker values (42)' | Out-Null
$r = Uninstall
Check 'uninstall: exit code 0' ($r.Code -eq 0) "exit=$($r.Code)"
Check 'servizi rimossi' (NoServices) ''
Check 'regola firewall rimossa' (-not (Get-NetFirewallRule -DisplayName 'Redmine HTTP' -ErrorAction SilentlyContinue)) ''
Check 'programmi rimossi' (-not (Test-Path (Join-Path $InstallDir 'ruby'))) ''
Check 'dati conservati (pgdata, credenziali)' ((Test-Path (Join-Path $InstallDir 'pgdata\PG_VERSION')) -and (Test-Path (Join-Path $InstallDir 'credentials.txt'))) ''

Section 'Reinstallazione sugli stessi dati'
$r = Install
Check 'setup: exit code 0' ($r.Code -eq 0) "exit=$($r.Code) in $($r.Sec) s"
Check 'database riutilizzato' ((Psql 'select id from install_marker') -eq '42') ''
Check 'Redmine risponde' ($(try { (Invoke-WebRequest "http://localhost:$HttpPort/login" -UseBasicParsing -TimeoutSec 10).StatusCode -eq 200 } catch { $false })) ''

Section 'Disinstallazione completa (/REMOVEDATA)'
$r = Uninstall @('/REMOVEDATA')
Check 'uninstall: exit code 0' ($r.Code -eq 0) "exit=$($r.Code)"
Start-Sleep 3
Check 'servizi rimossi' (NoServices) ''
Check 'cartella rimossa' (-not (Test-Path $InstallDir)) ''
Check 'porte libere' (-not (Get-NetTCPConnection -State Listen -LocalPort $HttpPort, $PgPort -ErrorAction SilentlyContinue)) ''
Check 'voce rimossa da App installate' (-not (Get-ChildItem HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall | Where-Object { (Get-ItemProperty $_.PSPath).DisplayName -like 'Redmine*' })) ''

Section 'Riepilogo installer'
$results | Format-Table -AutoSize -Wrap | Out-String -Width 200 | Write-Host
$fail = @($results | Where-Object Esito -eq 'FAIL').Count
Write-Host "Totale: $($results.Count)  PASS: $($results.Count - $fail)  FAIL: $fail"
'INSTALLER_TEST_DONE'
exit ([int]($fail -gt 0))
