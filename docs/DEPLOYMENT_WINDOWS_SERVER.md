# Windows Server Deployment (KYZ Ingestor + Dashboard API)

This guide deploys both services on Windows Server startup using Task Scheduler, without changing the SQL schema.

## 1) Prerequisites

- Windows Server 2019/2022
- Python 3.11 x64
- Node.js LTS
- ODBC Driver 18 for SQL Server
- Repo checked out at `C:\apps\kyz-energy-monitor`

## 2) Configure environment

```powershell
cd C:\apps\kyz-energy-monitor
copy .env.example .env
notepad .env
```

Set at minimum:
- `SQL_SERVER`, `SQL_DATABASE`, `SQL_USERNAME`, `SQL_PASSWORD`
- `MQTT_HOST` (and optional MQTT credentials)
- Optional dashboard auth: `DASHBOARD_AUTH_TOKEN`

## 3) Install ingestor + dashboard

```powershell
cd C:\apps\kyz-energy-monitor
.\scripts\windows\install_ingestor.ps1
.\scripts\windows\install_dashboard.ps1
```

## 4) Create startup tasks

```powershell
cd C:\apps\kyz-energy-monitor
.\scripts\windows\create_taskscheduler_jobs.ps1 -RunNow
```

This creates two startup tasks:
- `KYZ-Ingestor`
- `KYZ-Dashboard-API`

## 5) Verify service health

```powershell
.\scripts\windows\smoke_test.ps1 -BaseUrl http://localhost:8080 -FreshnessThresholdSeconds 1800
```

If auth is enabled:

```powershell
.\scripts\windows\smoke_test.ps1 -BaseUrl http://localhost:8080 -AuthToken '<token>' -FreshnessThresholdSeconds 1800
```

## Notes

- Ingestor logs: `logs\kyz_ingestor.log`
- Dashboard API logs: `logs\dashboard_api.log`
- Existing SQL table/scripts remain unchanged.
