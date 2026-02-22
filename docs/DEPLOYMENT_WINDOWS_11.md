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
.\.venv\Scripts\Activate.ps1
python -m pip install --upgrade pip
python -m pip install -r requirements.txt
python main.py --test-conn

Set-Location C:\apps\kyz-energy-monitor\dashboard\web
npm install
npm run build
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
python main.py
dashboard\api\.venv\Scripts\python.exe -m uvicorn dashboard.api.app:app --host 0.0.0.0 --port 8080
```

Use `scripts/windows/*.ps1` for automated install/task scheduler setup.
