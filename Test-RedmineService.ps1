#Requires -RunAsAdministrator
<#
    Verifica il servizio Redmine gestito da wsw: configurazione SCM, account effettivo di Puma,
    stop ordinato (senza "arresto imprevisto"), riavvio, ripresa automatica dopo un crash di Puma.
#>
param(
    [string]$InstallDir  = 'C:\Redmine',
    [string]$ServiceName = 'Redmine',
    [int]$HttpPort       = 3000
)
$ErrorActionPreference = 'Continue'
$Wsw    = Join-Path $InstallDir 'service\wsw.exe'
$LogDir = Join-Path $InstallDir 'logs'
$results = [System.Collections.Generic.List[object]]::new()
function Check([string]$Name, [bool]$Ok, [string]$Detail = '') {
    $esito = if ($Ok) { 'PASS' } else { 'FAIL' }
    $results.Add([pscustomobject]@{ Test = $Name; Esito = $esito; Dettaglio = $Detail })
    Write-Host ("[{0}] {1}  {2}" -f $esito, $Name, $Detail) -ForegroundColor ($(if ($Ok) { 'Green' } else { 'Red' }))
}
function Section([string]$Title) { Write-Host "`n==> $Title" -ForegroundColor Cyan }
function WaitFor([scriptblock]$Condition, [int]$TimeoutSec = 30) {
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($sw.Elapsed.TotalSeconds -lt $TimeoutSec) {
        try { if (& $Condition) { return $true } } catch {}
        Start-Sleep -Milliseconds 500
    }
    return $false
}
function LoginOk { try { (Invoke-WebRequest "http://localhost:$HttpPort/login" -UseBasicParsing -TimeoutSec 5).StatusCode -eq 200 } catch { $false } }
# Login vero con le credenziali iniziali: Redmine risponde con un redirect e poi chiede il cambio password.
# Con credenziali errate la risposta e' 200 con il form di login di nuovo.
function Test-AdminLogin {
    try {
        $base = "http://localhost:$HttpPort"
        $page = Invoke-WebRequest "$base/login" -SessionVariable session -UseBasicParsing
        $token = ([regex]::Match($page.Content, 'name="authenticity_token" value="([^"]+)"')).Groups[1].Value
        $post = Invoke-WebRequest "$base/login" -Method Post -WebSession $session -UseBasicParsing `
            -Body @{ authenticity_token = $token; username = 'admin'; password = 'admin' }
        # Dopo i redirect si arriva alla pagina di cambio password, che contiene il campo new_password
        return $post.Content -match 'name="new_password"'
    } catch { return $false }
}
function Puma { Get-CimInstance Win32_Process -Filter "Name='ruby.exe'" | Where-Object { $_.CommandLine -match 'puma' } | Select-Object -First 1 }
function Unexpected([datetime]$Since) {
    @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; ProviderName = 'Service Control Manager'; Id = 7031, 7034; StartTime = $Since } -ErrorAction SilentlyContinue |
        Where-Object { $_.Message -match "\b$ServiceName\b" })
}
function LogSince([datetime]$Since) {
    Get-ChildItem $LogDir -File -Filter "$ServiceName*" | ForEach-Object { Get-Content $_.FullName -Encoding UTF8 } |
        Where-Object { $_ -match '^(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})' -and [datetime]$Matches[1] -ge $Since.AddSeconds(-1) }
}

Section 'Configurazione'
$reg = Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Services\$ServiceName"
$cim = Get-CimInstance Win32_Service -Filter "Name='$ServiceName'"
Check 'servizio gestito da wsw' ($cim.PathName -match [regex]::Escape($Wsw)) $cim.PathName
Check 'account NetworkService' ($cim.StartName -eq 'NT AUTHORITY\NetworkService') $cim.StartName
Check 'avvio automatico ritardato' (($reg.Start -eq 2) -and ($reg.DelayedAutostart -eq 1)) "Start=$($reg.Start) Delayed=$($reg.DelayedAutostart)"
Check 'dipende da RedminePostgreSQL' (@($reg.DependOnService) -contains 'RedminePostgreSQL') "$($reg.DependOnService -join ',')"
Check 'nessun residuo WinSW' (-not (Test-Path (Join-Path $InstallDir "service\$ServiceName.xml"))) ''
Write-Host ((& $Wsw status --name $ServiceName --verbose 2>&1) | Out-String)

Section 'Servizio in esecuzione'
Check 'Redmine risponde (/login 200)' (WaitFor { LoginOk } 240) ''
$p = Puma
$owner = if ($p) { $o = Invoke-CimMethod -InputObject $p -MethodName GetOwner; "$($o.Domain)\$($o.User)" } else { '' }
Check 'Puma gira come NetworkService' ($owner -match 'NETWORK SERVICE|SERVIZIO DI RETE|NetworkService') "pid=$($p.ProcessId) owner=$owner"
$css = ([regex]::Match((Invoke-WebRequest "http://localhost:$HttpPort/login" -UseBasicParsing).Content, 'href="(/assets/[^"]+\.css)"')).Groups[1].Value
Check 'login admin/admin riuscito (prima installazione)' (Test-AdminLogin) 'POST /login -> redirect, poi cambio password obbligatorio'
Check 'asset statici serviti' ($css -and (Invoke-WebRequest "http://localhost:$HttpPort$css" -UseBasicParsing).StatusCode -eq 200) $css

Section 'Stop ordinato'
$t0 = Get-Date
$sw = [Diagnostics.Stopwatch]::StartNew()
Stop-Service $ServiceName -ErrorAction SilentlyContinue
$sec = [math]::Round($sw.Elapsed.TotalSeconds, 1)
Start-Sleep 2
$log = (LogSince $t0) -join "`n"
Check 'servizio fermato' ((Get-Service $ServiceName).Status -eq 'Stopped') "in $sec s"
Check 'stop entro lo stop-timeout (20s)' ($sec -lt 20) "$sec s"
Check 'Puma ha chiuso in modo ordinato' ($log -match 'Goodbye|Gracefully stopping') (($log -split "`n" | Select-String 'Goodbye|Gracefully|exited after' | ForEach-Object { $_.Line.Trim() }) -join ' | ')
Check 'nessun "arresto imprevisto" (7031/7034)' ((Unexpected $t0).Count -eq 0) ''
Check 'nessun processo Puma residuo' ($null -eq (Puma)) ''
Check 'porta libera' (-not (Get-NetTCPConnection -State Listen -LocalPort $HttpPort -ErrorAction SilentlyContinue)) ''

Section 'Riavvio'
Start-Service $ServiceName
Check 'Redmine risponde dopo lo start' (WaitFor { LoginOk } 240) "stato=$((Get-Service $ServiceName).Status)"

Section 'Crash di Puma -> ripresa automatica (--restart always, delay 10s)'
$t0 = Get-Date
$p = Puma
Stop-Process -Id $p.ProcessId -Force
Check 'Puma terminato a forza' (WaitFor { -not (Get-Process -Id $p.ProcessId -ErrorAction SilentlyContinue) } 10) "pid=$($p.ProcessId)"
Check 'servizio resta Running' ((Get-Service $ServiceName).Status -eq 'Running') ''
Check 'Redmine torna a rispondere' (WaitFor { LoginOk } 240) "nuovo pid=$((Puma).ProcessId)"
Check 'wsw ha registrato il riavvio' (((LogSince $t0) -join "`n") -match 'Restarting in') ''
Check 'nessun "arresto imprevisto" (7031/7034)' ((Unexpected $t0).Count -eq 0) ''

Section 'Riepilogo'
$results | Format-Table -AutoSize -Wrap | Out-String -Width 200 | Write-Host
$fail = @($results | Where-Object Esito -eq 'FAIL').Count
Write-Host "Totale: $($results.Count)  PASS: $($results.Count - $fail)  FAIL: $fail"
"REDMINE_TEST_DONE"
# Exit code esplicito: lo usano Test-Installer.ps1 e la pipeline
exit ([int]($fail -gt 0))
