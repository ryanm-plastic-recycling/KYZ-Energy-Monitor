# KYZ Energy Monitor MQTT -> Azure SQL Ingestor

Python **3.13** service that subscribes to MQTT topic `pri/energy/kyz/interval` and inserts interval rows into `dbo.KYZ_Interval` in Azure SQL. Supports **Windows 11 x64** deployment.

## Architecture

- MQTT ingestor (`main.py`) writes idempotent intervals into `dbo.KYZ_Interval`.
- Dashboard API (`dashboard/api`) serves metrics + static frontend assets from `dashboard/api/static`.
- React/Vite frontend (`dashboard/web`) provides Executive/Operations/Billing/Data Quality pages plus `/kiosk`.

## SQL scripts (single source of truth)

This application does not run DDL automatically. Apply SQL scripts manually:

- `sql/001_create_table.sql`
- `sql/002_indexes.sql`
- `sql/003_dashboard_views.sql`

## Windows 11 deployment quickstart (PowerShell)

1. Install prerequisites:
   - Python 3.13 x64
   - Node.js LTS (required to build dashboard frontend)
   - ODBC Driver 18 for SQL Server
2. Clone/copy repo to `C:\apps\kyz-energy-monitor`.
3. Configure `.env`:

```powershell
Set-Location C:\apps\kyz-energy-monitor
Copy-Item .env.example .env
notepad .env
```

4. Install and verify ingestor:

```powershell
python -m venv .venv
.\.venv\Scripts\Activate.ps1
python -m pip install --upgrade pip
python -m pip install -r requirements.txt
python main.py --test-conn
```

5. Build and install dashboard:

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
```

6. Run services:

```powershell
Set-Location C:\apps\kyz-energy-monitor
python main.py
dashboard\api\.venv\Scripts\python.exe -m uvicorn dashboard.api.app:app --host 0.0.0.0 --port 8080
```

Open:
- `http://localhost:8080/`
- `http://localhost:8080/kiosk?refresh=10&theme=dark`

## SQL credential model (ingestor vs dashboard)

- Ingestor (`main.py`) behavior is unchanged and continues to use `SQL_USERNAME` / `SQL_PASSWORD`.
- Dashboard API (`dashboard/api`) credential lookup order is:
  1. `SQL_RO_USERNAME` / `SQL_RO_PASSWORD` if both are set
  2. else `SQL_USERNAME` / `SQL_PASSWORD`

Recommended SQL users/permissions:

- `kyz_ingestor`: `INSERT` on `dbo.KYZ_Interval` (optional `SELECT` for diagnostics)
- `kyz_dashboard`: `SELECT` only on `dbo.KYZ_Interval` plus dashboard views

The dashboard health endpoint (`/api/health`) reports `credentialMode` as `"ro"` or `"rw"` and never returns usernames or passwords.

## Dashboard tariff/env settings

Optional `.env` settings used by dashboard billing calculations:

- `PLANT_NAME`
- `TARIFF_CUSTOMER_CHARGE` (default `120.00`)
- `TARIFF_DEMAND_RATE_PER_KW` (default `24.74`)
- `TARIFF_ENERGY_RATE_PER_KWH` (default `0.04143`)
- `TARIFF_RATCHET_PERCENT` (default `0.60`)
- `TARIFF_MIN_BILLING_KW` (default `50`)
- `API_SERIES_MAX_DAYS` (default `7`)
- `API_ALLOW_EXTENDED_RANGE` (default `false`)

## Operations docs and scripts

- `docs/DEPLOYMENT_WINDOWS_11.md`
- `docs/DEPLOYMENT_WINDOWS_SERVER.md`
- `docs/MOSQUITTO_SETUP.md`
- `docs/RUNBOOK.md`

Automation scripts (retained):
- `scripts/windows/install_ingestor.ps1`
- `scripts/windows/install_dashboard.ps1`
- `scripts/windows/create_taskscheduler_jobs.ps1`
- `scripts/windows/smoke_test.ps1`
