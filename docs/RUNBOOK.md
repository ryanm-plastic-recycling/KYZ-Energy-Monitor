# KYZ Energy Monitor Runbook

Operational checks for ingestor + dashboard API.

## Service status

```powershell
Get-ScheduledTask -TaskName 'KYZ-Ingestor','KYZ-Dashboard-API' | Get-ScheduledTaskInfo
```

## Health API

```powershell
Invoke-RestMethod http://localhost:8080/api/health
```

Expected:
- HTTP 200
- `dbConnected: true`
- `secondsSinceLatest`: integer freshness indicator

## Dashboard stale checklist

When kiosk/dashboard shows stale:

1. **Check API process/task state**
   - `KYZ-Dashboard-API` task is running.
2. **Check ingestor task state**
   - `KYZ-Ingestor` task is running.
3. **Check health endpoint freshness**
   - `secondsSinceLatest` should be within target (e.g., < 1800).
4. **Check DB connectivity**
   - `dbConnected` should be `true`.
5. **Check logs**
   - `logs\kyz_ingestor.log`
   - `logs\dashboard_api.log`
6. **Check MQTT broker**
   - Broker service running.
   - Topic `pri/energy/kyz/interval` receiving messages.
7. **Check auth token behavior**
   - If `DASHBOARD_AUTH_TOKEN` is set, API calls need header token.
   - Kiosk SSE uses query token in URL (`/api/stream?token=...`).


## Data retention policy

- `dbo.KYZ_Interval` is kept forever and is the system of record.
- `dbo.KYZ_Live15s` is retained for 7 days via `KYZ-Live15s-Retention`.
- `dbo.KYZ_MonthlyDemand` snapshot rows are kept forever.

## Common recovery actions

- Restart tasks:

```powershell
Stop-ScheduledTask -TaskName 'KYZ-Ingestor','KYZ-Dashboard-API'
Start-ScheduledTask -TaskName 'KYZ-Ingestor'
Start-ScheduledTask -TaskName 'KYZ-Dashboard-API'
```

- Re-run smoke test:

```powershell
.\scripts\windows\smoke_test.ps1 -BaseUrl http://localhost:8080 -FreshnessThresholdSeconds 1800
```

- If auth enabled:

```powershell
.\scripts\windows\smoke_test.ps1 -BaseUrl http://localhost:8080 -AuthToken '<token>' -FreshnessThresholdSeconds 1800
```
