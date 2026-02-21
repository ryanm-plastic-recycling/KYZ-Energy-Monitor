[CmdletBinding()]
param(
    [string]$RepoRoot = 'C:\apps\kyz-energy-monitor',
    [string]$PythonExe = 'python',
    [string]$NodeExe = 'npm'
)

$ErrorActionPreference = 'Stop'

Write-Host "Installing dashboard in $RepoRoot"
Set-Location $RepoRoot

if (-not (Test-Path '.env')) {
    Copy-Item '.env.example' '.env'
    Write-Host 'Created .env from .env.example. Fill in SQL settings (and optional DASHBOARD_* settings).'
}

Push-Location "$RepoRoot\dashboard\web"
& $NodeExe install
& $NodeExe run build
Pop-Location

New-Item -ItemType Directory -Force "$RepoRoot\dashboard\api\static" | Out-Null
Copy-Item -Recurse -Force "$RepoRoot\dashboard\web\dist\*" "$RepoRoot\dashboard\api\static\"

& $PythonExe -m venv "$RepoRoot\dashboard\api\.venv"
& "$RepoRoot\dashboard\api\.venv\Scripts\python.exe" -m pip install --upgrade pip
& "$RepoRoot\dashboard\api\.venv\Scripts\python.exe" -m pip install -r "$RepoRoot\dashboard\api\requirements.txt"

Write-Host 'KYZ dashboard install complete.'
