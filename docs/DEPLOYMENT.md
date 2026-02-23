# Deployment Notes

## Live 15s retention (Windows Server)

Run the retention SQL script once against the target database before enabling the scheduler job:

```powershell
sqlcmd -S <server> -d <database> -i .\sql\005_retention_live15s.sql
```

After deploying `scripts\windows\create_taskscheduler_jobs.ps1`, verify the scheduled retention task exists and runs nightly:

```powershell
Get-ScheduledTask -TaskName 'KYZ-Live15s-Retention'
Get-Content .\logs\KYZ-Live15s-Retention.out.log -Tail 20
Get-Content .\logs\KYZ-Live15s-Retention.err.log -Tail 20
```

A healthy setup shows the task in Task Scheduler and fresh timestamps in the retention log files after the scheduled run.
