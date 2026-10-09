#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Rimuove i servizi creati da Install-Redmine.ps1. Con -RemoveFiles cancella anche la cartella (DATI INCLUSI).
#>
[CmdletBinding()]
param(
    [string]$InstallDir         = 'C:\Redmine',
    [string]$PgServiceName      = 'RedminePostgreSQL',
    [string]$RedmineServiceName = 'Redmine',
    [switch]$RemoveFiles
)
$ErrorActionPreference = 'Stop'

if (Get-Service $RedmineServiceName -ErrorAction SilentlyContinue) {
    & (Join-Path $InstallDir 'service\wsw.exe') uninstall --name $RedmineServiceName
}
if (Get-Service $PgServiceName -ErrorAction SilentlyContinue) {
    Stop-Service $PgServiceName -ErrorAction SilentlyContinue
    & (Join-Path $InstallDir 'pgsql\bin\pg_ctl.exe') unregister -N $PgServiceName
}
Get-NetFirewallRule -DisplayName 'Redmine HTTP' -ErrorAction SilentlyContinue | Remove-NetFirewallRule

if ($RemoveFiles) {
    Remove-Item $InstallDir -Recurse -Force
    Write-Host "Rimossa la cartella $InstallDir"
} else {
    Write-Host "Servizi rimossi. I file (database incluso) sono ancora in $InstallDir"
}
