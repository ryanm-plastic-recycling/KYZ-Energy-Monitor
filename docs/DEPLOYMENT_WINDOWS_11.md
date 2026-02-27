# Deployment on Windows 11 x64

## Prerequisites

- Python 3.13 x64
- Node.js LTS
- ODBC Driver 18 for SQL Server

## Install

```powershell
Set-Location C:\apps\kyz-energy-monitor
Copy-Item .env.example .env
notepad .env

python -m venv .venv
.\.venv\Scripts\python.exe -m pip install --upgrade pip
.\.venv\Scripts\python.exe -m pip install -r requirements.txt
.\.venv\Scripts\python.exe main.py --test-conn

Set-Location C:\apps\kyz-energy-monitor\dashboard\web
npm.cmd install
npm.cmd run build
New-Item -ItemType Directory -Force C:\apps\kyz-energy-monitor\dashboard\api\static | Out-Null
Copy-Item -Force -Recurse .\dist\* C:\apps\kyz-energy-monitor\dashboard\api\static\

Set-Location C:\apps\kyz-energy-monitor
python -m venv dashboard\api\.venv
dashboard\api\.venv\Scripts\python.exe -m pip install --upgrade pip
dashboard\api\.venv\Scripts\python.exe -m pip install -r dashboard\api\requirements.txt
```

## Run

```powershell
Set-Location C:\apps\kyz-energy-monitor
.\.venv\Scripts\python.exe main.py
dashboard\api\.venv\Scripts\python.exe -m dashboard.api.run_server
```

Set `DASHBOARD_PORT` in `.env` for your preferred listener port.

## Troubleshooting (PowerShell)

### PowerShell blocks scripts

```powershell
Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy RemoteSigned
Get-ExecutionPolicy -List
```

### Verify ODBC Driver 18 is installed

```powershell
Get-OdbcDriver | Where-Object Name -Like "*ODBC Driver 18 for SQL Server*"
```

### Validate MQTT DNS and port reachability

```powershell
Resolve-DnsName your-mqtt-hostname
Test-NetConnection your-mqtt-hostname -Port 1883
```

Use `scripts/windows/*.ps1` for automated install/task scheduler setup.

Task Scheduler automation also includes:
- `KYZ-Live15s-Retention` (daily 02:05)
- `KYZ-MonthlyDemand-Refresh` (daily 02:10)
