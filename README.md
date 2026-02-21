# KYZ Energy Monitor MQTT -> Azure SQL Ingestor

Python 3.11 service that subscribes to MQTT topic `pri/energy/kyz/interval` and inserts interval rows into `dbo.KYZ_Interval` in Azure SQL.

## Architecture

- **microSD source-of-truth**: the PLC/edge device records energy interval data to local media first.
- **MQTT stream**: interval payloads are published on `pri/energy/kyz/interval`.
- **Azure SQL store**: this ingestor validates payloads and writes idempotent interval records to `dbo.KYZ_Interval`.
- **Grafana dashboard**: Grafana reads Azure SQL (table + reporting views) for plant operations displays.

## Behavior

- Subscribes to `pri/energy/kyz/interval` using `paho-mqtt`.
- Validates and parses payload JSON.
- Inserts into `dbo.KYZ_Interval` using `pyodbc` and **ODBC Driver 18 for SQL Server**.
- Idempotent insert logic: if `IntervalEnd` already exists, the message is ignored.
- Does **not** create or alter table schema at runtime.
- Logs to `./logs/kyz_ingestor.log` with daily rotation and 30-day retention.
- Includes `python main.py --test-conn` to verify SQL and MQTT connectivity.

## Expected Payload

```json
{
  "intervalEnd": "2026-01-31 14:15:00",
  "pulseCount": 42,
  "kWh": 0.25,
  "kW": 1.0,
  "total_kWh": 12345.67,
  "r17Exclude": false,
  "kyzInvalidAlarm": false
}
```

Required fields:
- `intervalEnd` (`YYYY-MM-DD HH:MM:SS`)
- `pulseCount` (int)
- `kWh` (number)
- `kW` (number)

Optional fields:
- `total_kWh` (number)
- `r17Exclude` (bool, omitted -> SQL `NULL`)
- `kyzInvalidAlarm` (bool, omitted -> SQL `NULL`)

## MQTT Publisher Setup (AutomationDirect Productivity Suite / PLC)

Recommended publisher settings:

- **Broker host/port**: your PACE Mosquitto host and port (typically `1883` for TCP, `8883` for TLS).
- **Topic**: `pri/energy/kyz/interval`
- **Payload format**: JSON object matching the schema above.
- **Cadence**: publish once per meter interval (for example every 15 minutes), with `intervalEnd` aligned to interval boundary.
- **QoS**: `1` (at-least-once delivery) to align with ingest idempotency.
- **Retain**: `false` for interval event streams.

Example payload template:

```json
{
  "intervalEnd": "YYYY-MM-DD HH:MM:SS",
  "pulseCount": 0,
  "kWh": 0.0,
  "kW": 0.0,
  "total_kWh": 0.0,
  "r17Exclude": false,
  "kyzInvalidAlarm": false
}
```

## MQTT Broker Setup Notes (PACE / Mosquitto)

- Install Mosquitto service on the PACE server and configure it for auto-start.
- Open firewall inbound rules only for required broker ports:
  - `1883/TCP` for non-TLS clients
  - `8883/TCP` for TLS clients
- Prefer username/password auth over anonymous access.
- Store credentials using Mosquitto password file tooling.
- Use ACL rules so publishers can write only to `pri/energy/kyz/interval` and consumers can read only required topics.
- For routed networks/VLANs, verify PLC-to-broker connectivity with explicit allow rules.

## Grafana Setup (Plant TV Dashboards)

1. **Add Azure SQL data source**
   - Configure Microsoft SQL Server datasource.
   - Point to Azure SQL server/database used by this ingestor.
   - Use a read-only SQL login for dashboards.

2. **Build panels**
   - Real-time status panel from `dbo.vw_KYZ_LatestInterval`.
   - Daily energy and peak demand panels from `dbo.vw_KYZ_DailySummary`.
   - Monthly billing demand estimate panel from `dbo.vw_KYZ_MonthlyBillingDemandEstimate`.

3. **Plant TV display settings**
   - Use dashboard kiosk mode (`&kiosk`) for full-screen rotation.
   - Set refresh interval based on interval cadence (commonly 1–5 minutes for display responsiveness).
   - If multiple TVs are used, run each on a least-privileged viewer account.

## Windows Server (PACE server) Setup

1. **Install Python 3.11**
   - Download/install Python 3.11 (64-bit).
   - Ensure `python` and `pip` are available in PATH.

2. **Install Microsoft ODBC Driver 18 for SQL Server**
   - Download/install: "ODBC Driver 18 for SQL Server" from Microsoft.
   - Verify installation in **ODBC Data Sources (64-bit)** > **Drivers**.

3. **Deploy project files**
   ```powershell
   mkdir C:\apps\kyz-energy-monitor
   # Copy repository contents into C:\apps\kyz-energy-monitor
   cd C:\apps\kyz-energy-monitor
   ```

4. **Create and activate virtual environment**
   ```powershell
   python -m venv .venv
   .\.venv\Scripts\activate
   ```

5. **Install dependencies**
   ```powershell
   pip install --upgrade pip
   pip install -r requirements.txt
   ```

6. **Configure environment**
   ```powershell
   copy .env.example .env
   notepad .env
   ```
   Set valid MQTT broker and Azure SQL credentials.

7. **Run connectivity check**
   ```powershell
   python main.py --test-conn
   ```

8. **Run service**
   ```powershell
   python main.py
   ```

9. **Run continuously on server (recommended)**
   - Use **Task Scheduler** (At startup + restart on failure), or
   - Use a service wrapper such as NSSM pointing to:
     - Program: `C:\apps\kyz-energy-monitor\.venv\Scripts\python.exe`
     - Arguments: `C:\apps\kyz-energy-monitor\main.py`
     - Start in: `C:\apps\kyz-energy-monitor`


## Windows Server Ops Docs

For hardened Windows deployment and operations, see:
- `docs/DEPLOYMENT_WINDOWS_SERVER.md`
- `docs/MOSQUITTO_SETUP.md`
- `docs/RUNBOOK.md`

Automation scripts (Task Scheduler + smoke test):
- `scripts/windows/install_ingestor.ps1`
- `scripts/windows/install_dashboard.ps1`
- `scripts/windows/create_taskscheduler_jobs.ps1`
- `scripts/windows/smoke_test.ps1`

## SQL Scripts

This application does not execute DDL. Apply these scripts manually via Azure Data Studio / VS Code:

- `sql/001_create_table.sql` (creates `dbo.KYZ_Interval`)
- `sql/002_indexes.sql` (optional filtered/reporting indexes)
- `sql/003_dashboard_views.sql` (Grafana-oriented reporting views)

Current optional indexes defined in `sql/002_indexes.sql`:
- `IX_KYZ_Interval_Total_kWh`
- `IX_KYZ_Interval_Exclude_Alarm`

## Manual SQL script (same as `sql/001_create_table.sql`)

```sql
CREATE TABLE dbo.KYZ_Interval (
    IntervalEnd      DATETIME2(0) NOT NULL,
    PulseCount       INT           NOT NULL,
    kWh              DECIMAL(18,6) NOT NULL,
    kW               DECIMAL(18,6) NOT NULL,
    Total_kWh        DECIMAL(18,6) NULL,
    R17Exclude       BIT           NULL,
    KyzInvalidAlarm  BIT           NULL,
    CONSTRAINT PK_KYZ_Interval PRIMARY KEY CLUSTERED (IntervalEnd)
);
```

## Notes

- Idempotency relies on `IntervalEnd` uniqueness in the existing table.
- If duplicates arrive, they are skipped and logged.

## Plant Energy Dashboard (Self-Hosted Web UI)

A built-in dashboard stack is available under `dashboard/`:
- `dashboard/api`: FastAPI backend that reads from `dbo.KYZ_Interval`
- `dashboard/web`: React + TypeScript frontend (dashboard + kiosk routes)

See `dashboard/README.md` for full installation and Windows Server service setup.

Run ingestor + dashboard together on the same server:

1. Start ingestor:
   ```bash
   python main.py
   ```
2. Start dashboard API:
   ```bash
   uvicorn dashboard.api.app:app --host 0.0.0.0 --port 8080
   ```
3. Open dashboard:
   - `http://<server>:8080/`
   - `http://<server>:8080/kiosk?refresh=10&theme=dark`
