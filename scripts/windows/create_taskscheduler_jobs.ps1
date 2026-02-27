param(
    [Parameter(Mandatory = $true)]
    [string]$RepoRoot,
    [string]$TaskUser = "SYSTEM",
    [switch]$RunNow
)

$ErrorActionPreference = "Stop"

Import-Module ScheduledTasks -ErrorAction Stop

$RepoRoot = (Resolve-Path -Path $RepoRoot).Path

Write-Host "Registering Task Scheduler jobs in $RepoRoot (RunAs=$TaskUser) ..."

$logsDir = Join-Path $RepoRoot "logs"
if (-not (Test-Path $logsDir)) {
    New-Item -ItemType Directory -Force -Path $logsDir | Out-Null
}

function New-KyzPrincipal {
    if ($TaskUser -eq "SYSTEM" -or $TaskUser -eq "NT AUTHORITY\SYSTEM") {
        return New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest
    }

    return New-ScheduledTaskPrincipal -UserId $TaskUser -LogonType S4U -RunLevel Highest
}

function New-KyzSettings {
    return New-ScheduledTaskSettingsSet `
        -AllowStartIfOnBatteries `
        -DontStopIfGoingOnBatteries `
        -StartWhenAvailable `
        -ExecutionTimeLimit (New-TimeSpan -Seconds 0) `
        -MultipleInstances IgnoreNew `
        -RestartCount 3 `
        -RestartInterval (New-TimeSpan -Minutes 1)
}

function Register-OrReplaceTask {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Exe,
        [Parameter(Mandatory = $true)][string]$Arguments,
        [Parameter(Mandatory = $true)]$Trigger
    )

    if (-not (Test-Path $Exe)) {
        throw "Executable not found: $Exe"
    }

    $action = New-ScheduledTaskAction -Execute $Exe -Argument $Arguments -WorkingDirectory $RepoRoot
    $task = New-ScheduledTask -Action $action -Trigger $Trigger -Principal (New-KyzPrincipal) -Settings (New-KyzSettings)

    $existing = Get-ScheduledTask -TaskName $Name -ErrorAction SilentlyContinue
    if ($existing) {
        try { Stop-ScheduledTask -TaskName $Name -ErrorAction SilentlyContinue } catch {}
    }

    Register-ScheduledTask -TaskName $Name -InputObject $task -Force | Out-Null
    Write-Host "Registered task: $Name"
}

$ingestorExe = Join-Path $RepoRoot ".venv\Scripts\python.exe"
$dashboardExe = Join-Path $RepoRoot "dashboard\api\.venv\Scripts\python.exe"

Register-OrReplaceTask -Name "KYZ-Ingestor" -Exe $ingestorExe -Arguments "main.py" -Trigger (New-ScheduledTaskTrigger -AtStartup)
Register-OrReplaceTask -Name "KYZ-Dashboard-API" -Exe $dashboardExe -Arguments "-m dashboard.api.run_server" -Trigger (New-ScheduledTaskTrigger -AtStartup)
Register-OrReplaceTask -Name "KYZ-Live15s-Retention" -Exe $ingestorExe -Arguments "scripts\windows\purge_live15s.py --retention-days 60" -Trigger (New-ScheduledTaskTrigger -Daily -At 2:05AM)
Register-OrReplaceTask -Name "KYZ-MonthlyDemand-Refresh" -Exe $ingestorExe -Arguments "scripts\windows\refresh_monthly_demand.py" -Trigger (New-ScheduledTaskTrigger -Daily -At 2:10AM)

if ($RunNow) {
    Start-ScheduledTask -TaskName "KYZ-Ingestor" | Out-Null
    Start-ScheduledTask -TaskName "KYZ-Dashboard-API" | Out-Null
    Start-ScheduledTask -TaskName "KYZ-Live15s-Retention" | Out-Null
    Start-ScheduledTask -TaskName "KYZ-MonthlyDemand-Refresh" | Out-Null
    Write-Host "Started tasks: KYZ-Ingestor, KYZ-Dashboard-API, KYZ-Live15s-Retention, KYZ-MonthlyDemand-Refresh"
}
