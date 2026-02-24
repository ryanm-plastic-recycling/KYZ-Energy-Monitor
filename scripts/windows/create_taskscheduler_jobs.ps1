[CmdletBinding()]
param(
    [string]$RepoRoot = 'C:\apps\kyz-energy-monitor',
    [string]$TaskUser = 'SYSTEM',
    [switch]$RunNow
)

$ErrorActionPreference = 'Stop'

function Register-OrReplaceTask {
    param(
        [string]$Name,
        [string]$Exe,
        [string]$Arguments,
        [string]$WorkingDir,
        [string]$TaskUser,
        [Parameter(Mandatory = $true)]
        [Microsoft.Management.Infrastructure.CimInstance]$Trigger
    )

    $action = New-ScheduledTaskAction -Execute $Exe -Argument $Arguments -WorkingDirectory $WorkingDir
    $principal = New-ScheduledTaskPrincipal -UserId $TaskUser -LogonType ServiceAccount -RunLevel Highest
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -RestartCount 999 -RestartInterval (New-TimeSpan -Minutes 1) -StartWhenAvailable

    Register-ScheduledTask -TaskName $Name -Action $action -Trigger $Trigger -Principal $principal -Settings $settings -Force | Out-Null
    Write-Host "Registered task: $Name"
}

$startupTrigger = New-ScheduledTaskTrigger -AtStartup
$dailyRetentionTrigger = New-ScheduledTaskTrigger -Daily -At 2:05AM
$dailyMonthlyDemandTrigger = New-ScheduledTaskTrigger -Daily -At 2:10AM

Register-OrReplaceTask -Name 'KYZ-Ingestor' -Exe "$RepoRoot\.venv\Scripts\python.exe" -Arguments 'main.py' -WorkingDir $RepoRoot -TaskUser $TaskUser -Trigger $startupTrigger
Register-OrReplaceTask -Name 'KYZ-Dashboard-API' -Exe "$RepoRoot\dashboard\api\.venv\Scripts\python.exe" -Arguments '-m uvicorn dashboard.api.app:app --host 0.0.0.0 --port 8080' -WorkingDir $RepoRoot -TaskUser $TaskUser -Trigger $startupTrigger

$retentionOutLog = "$RepoRoot\logs\KYZ-Live15s-Retention.out.log"
$retentionErrLog = "$RepoRoot\logs\KYZ-Live15s-Retention.err.log"
$retentionCmd = "\"$RepoRoot\.venv\Scripts\python.exe\" scripts\windows\purge_live15s.py --retention-days 7 1>>\"$retentionOutLog\" 2>>\"$retentionErrLog\""

Register-OrReplaceTask -Name 'KYZ-Live15s-Retention' -Exe 'cmd.exe' -Arguments "/c $retentionCmd" -WorkingDir $RepoRoot -TaskUser $TaskUser -Trigger $dailyRetentionTrigger

$monthlyDemandOutLog = "$RepoRoot\logs\KYZ-MonthlyDemand-Refresh.out.log"
$monthlyDemandErrLog = "$RepoRoot\logs\KYZ-MonthlyDemand-Refresh.err.log"
$monthlyDemandCmd = "\"$RepoRoot\.venv\Scripts\python.exe\" scripts\windows\refresh_monthly_demand.py 1>>\"$monthlyDemandOutLog\" 2>>\"$monthlyDemandErrLog\""

Register-OrReplaceTask -Name 'KYZ-MonthlyDemand-Refresh' -Exe 'cmd.exe' -Arguments "/c $monthlyDemandCmd" -WorkingDir $RepoRoot -TaskUser $TaskUser -Trigger $dailyMonthlyDemandTrigger

if ($RunNow) {
    Start-ScheduledTask -TaskName 'KYZ-Ingestor'
    Start-ScheduledTask -TaskName 'KYZ-Dashboard-API'
    Start-ScheduledTask -TaskName 'KYZ-Live15s-Retention'
    Start-ScheduledTask -TaskName 'KYZ-MonthlyDemand-Refresh'
    Write-Host 'Started all tasks.'
}
