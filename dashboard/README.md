# Plant Energy Dashboard

Self-hosted dashboard stack for KYZ interval data in `dbo.KYZ_Interval`.

## Overview

- **Backend API**: `dashboard/api` (FastAPI + pyodbc)
- **Frontend SPA**: `dashboard/web` (React + TypeScript + Vite + ECharts)
- **Static hosting**: build web app and copy `dashboard/web/dist/*` into `dashboard/api/static/`
- Uses existing `SQL_*` environment variables from the ingestor.

## API Endpoints

- `GET /api/health`
- `GET /api/latest`
- `GET /api/series?minutes=240&start=<iso>&end=<iso>`
- `GET /api/daily?days=14`
- `GET /api/monthly-demand?months=12`
- `GET /api/stream` (SSE, polls latest row every `DASHBOARD_SSE_POLL_SECONDS`, default 5s)

Optional API auth:
- Set `DASHBOARD_AUTH_TOKEN` to require auth on all `/api/*` routes.
- Clients can send token in either `X-Auth-Token` header or `?token=` query parameter (useful for kiosk SSE/EventSource).

## Environment Variables

Required (reuse from ingestor):
- `SQL_SERVER`
- `SQL_DATABASE`
- `SQL_USERNAME`
- `SQL_PASSWORD`

Dashboard-specific:
- `DASHBOARD_HOST` (default `0.0.0.0`)
- `DASHBOARD_PORT` (default `8080`)
- `DASHBOARD_AUTH_TOKEN` (optional)
- `DASHBOARD_SSE_POLL_SECONDS` (default `5`)

## Local Build + Run

### 1) Build frontend

```bash
cd dashboard/web
npm install
npm run build
```

### 2) Copy frontend into API static folder

```bash
# from repo root
mkdir -p dashboard/api/static
cp -r dashboard/web/dist/* dashboard/api/static/
```

### 3) Setup backend venv + install

```bash
# from repo root
python -m venv dashboard/api/.venv
source dashboard/api/.venv/bin/activate
pip install --upgrade pip
pip install -r dashboard/api/requirements.txt
```

### 4) Run API server

```bash
# from repo root
uvicorn dashboard.api.app:app --host ${DASHBOARD_HOST:-0.0.0.0} --port ${DASHBOARD_PORT:-8080}
```

Open:
- `http://<server>:8080/` for dashboard
- `http://<server>:8080/kiosk` for TV layout

## Windows Server Deployment

### Prerequisites

1. Install **Python 3.11 x64**
2. Install **Node.js LTS** (for frontend build)
3. Install **ODBC Driver 18 for SQL Server**

### Build frontend (PowerShell)

```powershell
cd C:\apps\kyz-energy-monitor\dashboard\web
npm install
npm run build
New-Item -ItemType Directory -Force C:\apps\kyz-energy-monitor\dashboard\api\static | Out-Null
Copy-Item -Force -Recurse .\dist\* C:\apps\kyz-energy-monitor\dashboard\api\static\
```

### Backend venv + run (PowerShell)

```powershell
cd C:\apps\kyz-energy-monitor
python -m venv dashboard\api\.venv
dashboard\api\.venv\Scripts\activate
pip install --upgrade pip
pip install -r dashboard\api\requirements.txt
uvicorn dashboard.api.app:app --host 0.0.0.0 --port 8080
```

## Run as a background process

### Option A: Task Scheduler

- Program/script:
  `C:\apps\kyz-energy-monitor\dashboard\api\.venv\Scripts\python.exe`
- Add arguments:
  `-m uvicorn dashboard.api.app:app --host 0.0.0.0 --port 8080`
- Start in:
  `C:\apps\kyz-energy-monitor`
- Trigger: At startup
- Recovery: Restart task on failure

### Option B: NSSM

```powershell
nssm install KYZ-Dashboard-API "C:\apps\kyz-energy-monitor\dashboard\api\.venv\Scripts\python.exe" "-m uvicorn dashboard.api.app:app --host 0.0.0.0 --port 8080"
nssm set KYZ-Dashboard-API AppDirectory "C:\apps\kyz-energy-monitor"
nssm start KYZ-Dashboard-API
```

## TV/Kiosk Setup

- Use Chromium/Edge kiosk mode:

```powershell
msedge.exe --kiosk "http://localhost:8080/kiosk?refresh=10&theme=dark" --edge-kiosk-type=fullscreen
```

- Recommended refresh parameter: `?refresh=10` or `?refresh=15`.
- If auth token is enabled, append `&token=<token>` in kiosk URL (LAN-only trusted TVs).

## Notes

- Dashboard API logs to `logs/dashboard_api.log` (daily rotation).
- Ingestor service in `main.py` is unchanged and can run in parallel on the same server.


## Windows automation scripts

Use scripts in `scripts/windows` from repo root:

- `install_ingestor.ps1`
- `install_dashboard.ps1`
- `create_taskscheduler_jobs.ps1` (creates `KYZ-Ingestor` + `KYZ-Dashboard-API` startup tasks)
- `smoke_test.ps1`

Operational runbook and deployment docs are under `docs/`:
- `docs/DEPLOYMENT_WINDOWS_SERVER.md`
- `docs/MOSQUITTO_SETUP.md`
- `docs/RUNBOOK.md`
