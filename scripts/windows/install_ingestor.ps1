[CmdletBinding()]
param(
    [string]$RepoRoot = 'C:\apps\kyz-energy-monitor',
    [string]$PythonExe = 'python'
)

$ErrorActionPreference = 'Stop'

Write-Host "Installing KYZ ingestor dependencies in $RepoRoot"
Set-Location $RepoRoot

if (-not (Test-Path '.env')) {
    Copy-Item '.env.example' '.env'
    Write-Host 'Created .env from .env.example. Fill in SQL and MQTT settings before starting services.'
}

& $PythonExe -m venv .venv
& "$RepoRoot\.venv\Scripts\python.exe" -m pip install --upgrade pip
& "$RepoRoot\.venv\Scripts\python.exe" -m pip install -r requirements.txt

Write-Host 'Running ingestor connectivity test...'
& "$RepoRoot\.venv\Scripts\python.exe" main.py --test-conn

Write-Host 'KYZ ingestor install complete.'
