#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Rimuove i servizi creati da Install-Redmine.ps1. Con -RemoveFiles cancella anche la cartella (DATI INCLUSI).
#>
[CmdletBinding()]
param(
    [string]$InstallDir         = 'C:\Redmine',
    [string]$DbServiceName      = 'RedmineMariaDB',
    [string]$RedmineServiceName = 'Redmine',
    [switch]$RemoveFiles
)
$ErrorActionPreference = 'Stop'

if (Get-Service $RedmineServiceName -ErrorAction SilentlyContinue) {
    & (Join-Path $InstallDir 'service\wsw.exe') uninstall --name $RedmineServiceName
}
if (Get-Service $DbServiceName -ErrorAction SilentlyContinue) {
    Stop-Service $DbServiceName -Force -ErrorAction SilentlyContinue
    sc.exe delete $DbServiceName | Out-Null
    for ($i = 0; $i -lt 30 -and (Get-Service $DbServiceName -ErrorAction SilentlyContinue); $i++) { Start-Sleep 1 }
}
Get-NetFirewallRule -DisplayName 'Redmine HTTP' -ErrorAction SilentlyContinue | Remove-NetFirewallRule

if ($RemoveFiles) {
    Remove-Item $InstallDir -Recurse -Force
    Write-Host "Rimossa la cartella $InstallDir"
} else {
    Write-Host "Servizi rimossi. I file (database incluso) sono ancora in $InstallDir"
}
