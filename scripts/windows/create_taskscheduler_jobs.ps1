param(
    [string]$RepoRoot = "C:\apps\kyz-energy-monitor",
    [string]$TaskUser = "SYSTEM",
    [switch]$RunNow,
    [int]$RetentionDays = 7
)

$ErrorActionPreference = "Stop"

Write-Host "Registering Task Scheduler jobs in $RepoRoot (RunAs=$TaskUser) ..."

$logsDir = Join-Path $RepoRoot "logs"
if (-not (Test-Path $logsDir)) {
    New-Item -ItemType Directory -Force -Path $logsDir | Out-Null
}

function Register-OrReplaceTask {
    param(
        [Parameter(Mandatory=$true)][string]$Name,
        [Parameter(Mandatory=$true)][string]$Exe,
        [Parameter(Mandatory=$true)][string]$Arguments,
        [Parameter(Mandatory=$true)]$Trigger
    )

    if (-not (Test-Path $Exe)) {
        throw "Executable not found: $Exe"
    }

    $action = New-ScheduledTaskAction -Execute $Exe -Argument $Arguments -WorkingDirectory $RepoRoot

    if ($TaskUser -eq "SYSTEM" -or $TaskUser -eq "NT AUTHORITY\SYSTEM") {
        $principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest
    } else {
        # If you ever use a non-SYSTEM user, you’ll need to adjust to a passworded principal.
        $principal = New-ScheduledTaskPrincipal -UserId $TaskUser -LogonType Password -RunLevel Highest
    }

    $settings = New-ScheduledTaskSettingsSet `
        -AllowStartIfOnBatteries `
        -DontStopIfGoingOnBatteries `
        -StartWhenAvailable `
        -ExecutionTimeLimit (New-TimeSpan -Hours 72) `
        -MultipleInstances IgnoreNew

    $task = New-ScheduledTask -Action $action -Trigger $Trigger -Principal $principal -Settings $settings

    try {
        $existing = Get-ScheduledTask -TaskName $Name -ErrorAction SilentlyContinue
        if ($existing) {
            try { Stop-ScheduledTask -TaskName $Name -ErrorAction SilentlyContinue } catch {}
        }
        Register-ScheduledTask -TaskName $Name -InputObject $task -Force | Out-Null
        Write-Host "Registered task: $Name"
    } catch {
        throw "Failed to register task '$Name': $($_.Exception.Message)"
    }
}

# --- Main tasks ---
$ingestorExe  = Join-Path $RepoRoot ".venv\Scripts\python.exe"
$dashboardExe = Join-Path $RepoRoot "dashboard\api\.venv\Scripts\python.exe"

Register-OrReplaceTask -Name "KYZ-Ingestor" -Exe $ingestorExe -Arguments "main.py" -Trigger (New-ScheduledTaskTrigger -AtStartup)

Register-OrReplaceTask -Name "KYZ-Dashboard-API" -Exe $dashboardExe -Arguments "-m uvicorn dashboard.api.app:app --host 0.0.0.0 --port 8080" -Trigger (New-ScheduledTaskTrigger -AtStartup)

# --- 7-day retention for Live15s ---
# Runs daily at 2:05 AM local server time
$retentionExe = $ingestorExe
$retentionArgs = "scripts\windows\purge_live15s.py --retention-days $RetentionDays"
Register-OrReplaceTask -Name "KYZ-Live15s-Retention" -Exe $retentionExe -Arguments $retentionArgs -Trigger (New-ScheduledTaskTrigger -Daily -At 2:05AM)

if ($RunNow) {
    Start-ScheduledTask -TaskName "KYZ-Ingestor" | Out-Null
    Start-ScheduledTask -TaskName "KYZ-Dashboard-API" | Out-Null
    Start-ScheduledTask -TaskName "KYZ-Live15s-Retention" | Out-Null
    Write-Host "Started tasks (including retention)."
}