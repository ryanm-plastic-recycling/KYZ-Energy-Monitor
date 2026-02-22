# Plant Energy Dashboard

Self-hosted dashboard stack for KYZ interval data in `dbo.KYZ_Interval`, supporting **Windows 11 x64** and **Python 3.13**.

## Stack

- Backend API: `dashboard/api` (FastAPI + pyodbc)
- Frontend SPA: `dashboard/web` (React + TypeScript + Vite + ECharts)
- Static hosting: copy `dashboard/web/dist/*` into `dashboard/api/static/`

## Prerequisites

- Python 3.13 x64
- Node.js LTS (required for frontend build)
- ODBC Driver 18 for SQL Server

## API endpoints

- `GET /api/health`
- `GET /api/metrics`
- `GET /api/latest`
- `GET /api/series?minutes=240&start=<iso>&end=<iso>`
- `GET /api/summary`
- `GET /api/billing?months=24`
- `GET /api/quality`
- `GET /api/daily`
- `GET /api/monthly-demand`
- `GET /api/stream`

Optional API auth remains unchanged: `DASHBOARD_AUTH_TOKEN` can be provided in `X-Auth-Token` header or `?token=` query string.

## PowerShell build/run

```powershell
Set-Location C:\apps\kyz-energy-monitor\dashboard\web
npm install
npm run build
New-Item -ItemType Directory -Force C:\apps\kyz-energy-monitor\dashboard\api\static | Out-Null
Copy-Item -Force -Recurse .\dist\* C:\apps\kyz-energy-monitor\dashboard\api\static\

Set-Location C:\apps\kyz-energy-monitor
python -m venv dashboard\api\.venv
dashboard\api\.venv\Scripts\python.exe -m pip install --upgrade pip
dashboard\api\.venv\Scripts\python.exe -m pip install -r dashboard\api\requirements.txt
dashboard\api\.venv\Scripts\python.exe -m uvicorn dashboard.api.app:app --host 0.0.0.0 --port 8080
```

Routes:
- `/` Executive default
- `/operations`
- `/billing-risk`
- `/data-quality`
- `/kiosk` (TV mode)

## Logging

Dashboard API and uvicorn logs are written to `logs/dashboard_api.log` with daily rotation and 30-day retention.
