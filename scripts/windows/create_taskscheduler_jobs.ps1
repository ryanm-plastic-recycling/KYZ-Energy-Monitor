param(
    [Parameter(Mandatory=$true)]
    [string]$RepoRoot,

    [string]$TaskUser = "SYSTEM",

    [switch]$RunNow,

    [int]$RetentionDays = 7,

    # Local time on the server
    [string]$RetentionTime = "02:10"
)

$ErrorActionPreference = "Stop"

if (-not (Test-Path $RepoRoot)) {
    throw "RepoRoot not found: $RepoRoot"
}

Import-Module ScheduledTasks

$ingestorTask   = "KYZ-Ingestor"
$dashboardTask  = "KYZ-Dashboard-API"
$retentionTask  = "KYZ-Live15s-Retention"

$logsDir = Join-Path $RepoRoot "logs"
New-Item -ItemType Directory -Force -Path $logsDir | Out-Null

$pyIngestor  = Join-Path $RepoRoot ".venv\Scripts\python.exe"
$pyDashApi   = Join-Path $RepoRoot "dashboard\api\.venv\Scripts\python.exe"
$purgeScript = Join-Path $RepoRoot "scripts\windows\purge_live15s.py"

if (-not (Test-Path $pyIngestor)) { throw "Missing: $pyIngestor (run install_ingestor.ps1 first)" }
if (-not (Test-Path $pyDashApi))  { throw "Missing: $pyDashApi (run install_dashboard.ps1 first)" }
if (-not (Test-Path $purgeScript)) { throw "Missing: $purgeScript" }

# Principal (SYSTEM only, by design)
if ($TaskUser.ToUpper() -ne "SYSTEM") {
    throw "This script currently supports TaskUser=SYSTEM only (no password handling)."
}
$principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest

# Settings: do NOT stop after 72 hours; restart on failure
$settingsLongRun = New-ScheduledTaskSettingsSet `
    -ExecutionTimeLimit ([TimeSpan]::Zero) `
    -RestartCount 3 `
    -RestartInterval (New-TimeSpan -Minutes 1) `
    -StartWhenAvailable `
    -MultipleInstances IgnoreNew

$settingsShortRun = New-ScheduledTaskSettingsSet `
    -ExecutionTimeLimit (New-TimeSpan -Minutes 30) `
    -RestartCount 1 `
    -RestartInterval (New-TimeSpan -Minutes 5) `
    -StartWhenAvailable `
    -MultipleInstances IgnoreNew

# Actions
$ingestorAction = New-ScheduledTaskAction `
    -Execute $pyIngestor `
    -Argument "main.py" `
    -WorkingDirectory $RepoRoot

$dashboardAction = New-ScheduledTaskAction `
    -Execute $pyDashApi `
    -Argument "-m uvicorn dashboard.api.app:app --host 0.0.0.0 --port 8080" `
    -WorkingDirectory $RepoRoot

$retentionAction = New-ScheduledTaskAction `
    -Execute $pyIngestor `
    -Argument ("{0} --retention-days {1}" -f $purgeScript, $RetentionDays) `
    -WorkingDirectory $RepoRoot

# Triggers
$startupTrigger = New-ScheduledTaskTrigger -AtStartup

# Parse retention time (today's date with that time; scheduler only uses the time portion)
$retTime = Get-Date $RetentionTime
$dailyTrigger = New-ScheduledTaskTrigger -Daily -At $retTime

function ReRegister-Task {
    param(
        [string]$Name,
        $Action,
        $Trigger,
        $Settings
    )

    if (Get-ScheduledTask -TaskName $Name -ErrorAction SilentlyContinue) {
        Unregister-ScheduledTask -TaskName $Name -Confirm:$false
    }

    Register-ScheduledTask -TaskName $Name -Action $Action -Trigger $Trigger -Principal $principal -Settings $Settings | Out-Null
    Write-Host "Registered task: $Name"
}

ReRegister-Task -Name $ingestorTask  -Action $ingestorAction  -Trigger $startupTrigger -Settings $settingsLongRun
ReRegister-Task -Name $dashboardTask -Action $dashboardAction -Trigger $startupTrigger -Settings $settingsLongRun
ReRegister-Task -Name $retentionTask -Action $retentionAction -Trigger $dailyTrigger   -Settings $settingsShortRun

if ($RunNow) {
    Start-ScheduledTask -TaskName $ingestorTask
    Start-ScheduledTask -TaskName $dashboardTask
    Write-Host "Started: $ingestorTask, $dashboardTask"
}
