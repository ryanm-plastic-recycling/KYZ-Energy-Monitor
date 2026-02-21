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
        [string]$TaskUser
    )

    $action = New-ScheduledTaskAction -Execute $Exe -Argument $Arguments -WorkingDirectory $WorkingDir
    $trigger = New-ScheduledTaskTrigger -AtStartup
    $principal = New-ScheduledTaskPrincipal -UserId $TaskUser -LogonType ServiceAccount -RunLevel Highest
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -RestartCount 999 -RestartInterval (New-TimeSpan -Minutes 1) -StartWhenAvailable

    Register-ScheduledTask -TaskName $Name -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force | Out-Null
    Write-Host "Registered task: $Name"
}

Register-OrReplaceTask -Name 'KYZ-Ingestor' -Exe "$RepoRoot\.venv\Scripts\python.exe" -Arguments 'main.py' -WorkingDir $RepoRoot -TaskUser $TaskUser
Register-OrReplaceTask -Name 'KYZ-Dashboard-API' -Exe "$RepoRoot\dashboard\api\.venv\Scripts\python.exe" -Arguments '-m uvicorn dashboard.api.app:app --host 0.0.0.0 --port 8080' -WorkingDir $RepoRoot -TaskUser $TaskUser

if ($RunNow) {
    Start-ScheduledTask -TaskName 'KYZ-Ingestor'
    Start-ScheduledTask -TaskName 'KYZ-Dashboard-API'
    Write-Host 'Started both tasks.'
}
