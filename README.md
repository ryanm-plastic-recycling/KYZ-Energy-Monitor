# KYZ Energy Monitor MQTT -> Azure SQL Ingestor

Python **3.13** service that subscribes to MQTT topic `pri/energy/kyz/interval` and inserts interval rows into `dbo.KYZ_Interval` in Azure SQL. Supports **Windows 11 x64** deployment.


## MQTT payload formats

The ingestor accepts `pri/energy/kyz/interval` in either full or minimal format:

1. Full JSON (backward compatible):

```json
{"intervalEnd":"YYYY-MM-DD HH:MM:SS","pulseCount":42,"kWh":0.42,"kW":1.68,"total_kWh":1234.5,"r17Exclude":false,"kyzInvalidAlarm":false}
```

2. Minimal PLC-friendly formats (server computes interval and power):

- Minimal JSON:

```json
{"d":42,"t":1234567,"r17Exclude":1,"kyzInvalidAlarm":0}
```

Also accepted:

```json
{"pulseDelta":42,"pulseTotal":1234567}
```

- Key/value string:

```text
d=42,t=1234567,r17Exclude=1,kyzInvalidAlarm=0
```

Legacy variant also accepted:

```text
d=42,1234567
```

When minimal payloads are used, the ingestor computes `intervalEnd`, `kWh`, `kW`, and optional `total_kWh` from server time and KYZ scaling settings. Optional `r17Exclude` and `kyzInvalidAlarm` flags can be provided in minimal JSON or packed key/value payloads; the ingestor ORs each flag across the full 15-minute interval bucket so any `1` in the bucket persists as `1` in `dbo.KYZ_Interval`.

### Units (important)

- `KYZ_PULSES_PER_KWH` is **pulses per kWh** (not kWh per pulse).
- Server conversion is: `kWh = pulseCount / KYZ_PULSES_PER_KWH`.
- If your PLC is configured as `1 pulse = 1.7 kWh`, set `KYZ_PULSES_PER_KWH=0.5882352941` (that is `1 / 1.7`).
- A pulse is an energy quantum (kWh).
- kW is derived from energy over the bucket duration (`kW = kWh * 3600 / bucket_seconds`).

## Architecture

- MQTT ingestor (`main.py`) writes idempotent intervals into `dbo.KYZ_Interval`.
- Dashboard API (`dashboard/api`) serves metrics + static frontend assets from `dashboard/api/static`.
- React/Vite frontend (`dashboard/web`) provides Executive/Operations/Billing/Data Quality pages plus `/kiosk`.

## SQL scripts (single source of truth)

This application does not run DDL automatically. Apply SQL scripts manually:

- `sql/001_create_table.sql`
- `sql/002_indexes.sql`
- `sql/003_dashboard_views.sql`
- `sql/010_plc_csv_ingest_log.sql`

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
dashboard\api\.venv\Scripts\python.exe -m dashboard.api.run_server
```

Set `DASHBOARD_HOST`/`DASHBOARD_PORT` in `.env` to control where the dashboard listens. For remote access, allow/forward the chosen port in Windows Firewall and router/NAT, and set `DASHBOARD_AUTH_TOKEN`.

Open:
- `http://localhost:<DASHBOARD_PORT>/`
- `http://localhost:<DASHBOARD_PORT>/kiosk?refresh=10&theme=dark`


## PLC CSV authoritative backfill

`dbo.KYZ_Interval` remains the canonical interval table for dashboard/billing queries. MQTT still inserts near-real-time interval rows, but PLC CSV imports are authoritative and will upsert (insert or overwrite) the same `IntervalEnd` records when CSV files arrive.

Workflow:
- Drop PLC CSV files into `PLC_CSV_DROP_DIR` (defaults to `plc_csv_drop` under repo root).
- Scheduled task `KYZ-PLC-CSV-Sync` runs hourly and imports only new/changed files (size/mtime/hash tracked in `dbo.KYZ_PlcCsvIngestLog`).
- Optional archive move can be enabled after successful import.

PLC CSV env vars:
- `PLC_CSV_DROP_DIR` (optional; default `repo_root/plc_csv_drop`)
- `PLC_CSV_GLOB` (optional; default `*.csv`)
- `PLC_CSV_MIN_AGE_SECONDS` (optional; default `10`)
- `PLC_CSV_MOVE_TO_ARCHIVE` (optional; default `false`)
- `PLC_CSV_ARCHIVE_DIR` (optional; used when move-to-archive is enabled)

Run manually:

```powershell
.\.venv\Scripts\python.exe scripts\windows\plc_csv_sync.py
```

## SQL credential model (ingestor vs dashboard)

- Ingestor (`main.py`) behavior is unchanged and continues to use `SQL_USERNAME` / `SQL_PASSWORD`.
- Dashboard API (`dashboard/api`) credential lookup order is:
  1. `SQL_RO_USERNAME` / `SQL_RO_PASSWORD` if both are set
  2. else `SQL_USERNAME` / `SQL_PASSWORD`

Recommended SQL users/permissions:

- `kyz_ingestor`: `INSERT` on `dbo.KYZ_Interval` (optional `SELECT` for diagnostics)
- `kyz_dashboard`: `SELECT` only on `dbo.KYZ_Interval` plus dashboard views

The dashboard health endpoint (`/api/health`) reports `credentialMode` as `"ro"` or `"rw"` and never returns usernames or passwords.

## KYZ minimal payload env settings

For minimal payload mode, configure:

- `KYZ_PULSES_PER_KWH` (**required** for minimal payloads, units: pulses per kWh)
- `KYZ_INTERVAL_MINUTES` (default `15`)
- `KYZ_INTERVAL_GRACE_SECONDS` (default `30`)

`intervalEnd` is aligned by server clock to interval boundaries with grace handling near boundary crossings.

## Dashboard tariff/env settings

Optional `.env` settings used by dashboard billing calculations:

- `PLANT_NAME`
- `TARIFF_CUSTOMER_CHARGE` (default `120.00`)
- `TARIFF_DEMAND_RATE_PER_KW` (default `24.74`)
- `TARIFF_ENERGY_RATE_PER_KWH` (default `0.04143`)
- `TARIFF_RATCHET_PERCENT` (default `0.60`)
- `TARIFF_MIN_BILLING_KW` (default `50`)
- `BILLING_ANCHOR_DATE` (optional; `YYYY-MM-DD` or ISO datetime, local naive time)
- `API_SERIES_MAX_DAYS` (default `60`)
- `API_ALLOW_EXTENDED_RANGE` (default `false`)


## Data retention policy

- `dbo.KYZ_Interval`: kept forever (system of record).
- `dbo.KYZ_Live15s`: retained for 60 days by scheduled task `KYZ-Live15s-Retention`.
- `dbo.KYZ_MonthlyDemand`: kept forever as the monthly demand snapshot used for ratchet billing.

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
- `scripts/windows/mqtt_probe.py`


## Billing period anchor (utility meter-read cycle)

By default, dashboard billing endpoints use calendar months. Set `BILLING_ANCHOR_DATE` to enable anchored billing periods (for example, 17th to 17th).

How to choose the anchor from a real utility bill:
- Find the *start* timestamp/date of a billing cycle on the bill (often “Service From”).
- Use that as `BILLING_ANCHOR_DATE` in local plant time.
- If your bill only shows dates, use midnight (`YYYY-MM-DD`); if it shows a timestamp, use the full ISO datetime.
- Keep the anchor stable over time so ratchet history aligns across prior 11 billing periods.

With `BILLING_ANCHOR_DATE` unset, API/UI behavior remains calendar-month based.
