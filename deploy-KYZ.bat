@echo off
setlocal EnableExtensions EnableDelayedExpansion

REM =========================================================
REM  KYZ Energy Monitor - deploy-KYZ.bat
REM
REM  - Mirrors repo from SRC (folder containing this .bat) -> DST
REM  - Preserves runtime artifacts in DST (.env, venvs, logs, node_modules, built static)
REM  - Stops Task Scheduler tasks with a HARD-KILL fallback if they refuse to stop
REM  - Runs PowerShell installers + builds dashboard + publishes static
REM  - Re-registers tasks + smoke test
REM  - ALWAYS pauses so you can read output
REM =========================================================

set "DST=C:\apps\kyz-energy-monitor"
set "NPM=npm.cmd"

REM Task names created by scripts/windows/create_taskscheduler_jobs.ps1
set "TASK_INGESTOR=KYZ-Ingestor"
set "TASK_DASH=KYZ-Dashboard-API"
set "TASK_RETENTION=KYZ-Live15s-Retention"
set "TASK_MONTHLY=KYZ-MonthlyDemand-Refresh"

REM Legacy task names from older iterations (best-effort stop)
set "TASK_INGESTOR_LEGACY=KYZ Ingestor"
set "TASK_DASH_LEGACY=KYZ Dashboard"

REM Repo root = folder containing this bat file
set "SRC=%~dp0"
if "%SRC:~-1%"=="\" set "SRC=%SRC:~0,-1%"

set "RC=0"

REM Kill patterns used for hard-kill fallback (PowerShell -like wildcards)
set "KILLPAT_INGESTOR=*%DST%\.venv\Scripts\python.exe*main.py*"
set "KILLPAT_DASH=*%DST%\dashboard\api\.venv\Scripts\python.exe*-m uvicorn*dashboard.api.app:app*"
set "KILLPAT_RETENTION=*%DST%\.venv\Scripts\python.exe*purge_live15s.py*"
set "KILLPAT_MONTHLY=*%DST%\.venv\Scripts\python.exe*refresh_monthly_demand.py*"

echo.
echo =========================================================
echo Deploying KYZ Energy Monitor
echo   SRC: %SRC%
echo   DST: %DST%
echo =========================================================
echo.

REM ----- Must be admin -----
net session >nul 2>&1
if errorlevel 1 (
  echo [ERROR] Not running as Administrator.
  echo         Right-click deploy-KYZ.bat and choose "Run as administrator".
  set "RC=1"
  goto :END
)

REM ----- Sanity check repo -----
if not exist "%SRC%\scripts\windows\install_ingestor.ps1" (
  echo [ERROR] Source path does not look like KYZ repo:
  echo         %SRC%
  set "RC=1"
  goto :END
)

REM ----- Ensure destination folders -----
if not exist "%DST%" mkdir "%DST%" >nul 2>&1
if not exist "%DST%\logs" mkdir "%DST%\logs" >nul 2>&1

REM ----- Stop long-running tasks (these MUST stop or deployment will be flaky) -----
echo [INFO] Stopping scheduled tasks (if present)...
call :StopTask "%TASK_INGESTOR%" "%KILLPAT_INGESTOR%"
if errorlevel 1 set "RC=1" & goto :END

call :StopTask "%TASK_DASH%" "%KILLPAT_DASH%"
if errorlevel 1 set "RC=1" & goto :END

REM Stop short tasks too (best effort; do not fail deploy if they don't exist)
call :StopTask "%TASK_RETENTION%" "%KILLPAT_RETENTION%"
call :StopTask "%TASK_MONTHLY%" "%KILLPAT_MONTHLY%"

REM Stop legacy tasks if they exist (best effort)
call :StopTask "%TASK_INGESTOR_LEGACY%" "%KILLPAT_INGESTOR%"
call :StopTask "%TASK_DASH_LEGACY%" "%KILLPAT_DASH%"

REM Extra safety: kill any stray processes even if task metadata lies
call :KillByCmdLine "%KILLPAT_INGESTOR%"
call :KillByCmdLine "%KILLPAT_DASH%"

echo.
echo [INFO] Mirroring repo to live folder (preserving runtime artifacts)...
robocopy "%SRC%" "%DST%" /MIR /R:2 /W:2 /FFT /Z /NP ^
  /XD ".git" ".venv" "logs" "node_modules" ^
      "dashboard\api\.venv" ^
      "dashboard\web\node_modules" ^
      "dashboard\web\dist" ^
      "dashboard\api\static" ^
  /XF ".env" "*.log"

set "ROBO=%ERRORLEVEL%"
REM Robocopy: 0-7 are success, 8+ are failure
if %ROBO% GEQ 8 (
  echo [ERROR] Robocopy failed with code %ROBO%
  set "RC=%ROBO%"
  goto :END
)

echo.
echo [INFO] Running install_ingestor.ps1...
powershell -NoProfile -ExecutionPolicy Bypass -File "%DST%\scripts\windows\install_ingestor.ps1" -RepoRoot "%DST%" -PythonExe "python"
if errorlevel 1 (
  echo [ERROR] install_ingestor.ps1 failed.
  set "RC=1"
  goto :END
)

echo.
echo [INFO] Running install_dashboard.ps1...
powershell -NoProfile -ExecutionPolicy Bypass -File "%DST%\scripts\windows\install_dashboard.ps1" -RepoRoot "%DST%" -PythonExe "python" -NodeExe "%NPM%"
if errorlevel 1 (
  echo [ERROR] install_dashboard.ps1 failed.
  set "RC=1"
  goto :END
)

echo.
echo [INFO] Forcing dashboard frontend build + static publish...
cd /d "%DST%\dashboard\web"
if errorlevel 1 (
  echo [ERROR] Missing folder: %DST%\dashboard\web
  set "RC=1"
  goto :END
)

call %NPM% install
if errorlevel 1 (
  echo [ERROR] npm install failed
  set "RC=1"
  goto :END
)

call %NPM% run build
if errorlevel 1 (
  echo [ERROR] npm run build failed
  set "RC=1"
  goto :END
)

if not exist "%DST%\dashboard\api\static" mkdir "%DST%\dashboard\api\static" >nul 2>&1
robocopy "%DST%\dashboard\web\dist" "%DST%\dashboard\api\static" /MIR /FFT /R:2 /W:2
set "ROBO2=%ERRORLEVEL%"
if %ROBO2% GEQ 8 (
  echo [ERROR] Robocopy dist->static failed with code %ROBO2%
  set "RC=%ROBO2%"
  goto :END
)

if not exist "%DST%\dashboard\api\static\index.html" (
  echo [ERROR] dashboard\api\static\index.html is missing after build/copy.
  set "RC=1"
  goto :END
)

echo.
echo [INFO] Registering/updating Scheduled Tasks + starting them...
powershell -NoProfile -ExecutionPolicy Bypass -File "%DST%\scripts\windows\create_taskscheduler_jobs.ps1" -RepoRoot "%DST%" -TaskUser "SYSTEM" -RunNow
if errorlevel 1 (
  echo [ERROR] create_taskscheduler_jobs.ps1 failed
  set "RC=1"
  goto :END
)

echo.
echo [INFO] Running smoke test...
powershell -NoProfile -ExecutionPolicy Bypass -File "%DST%\scripts\windows\smoke_test.ps1" -BaseUrl "http://localhost:8080" -FreshnessThresholdSeconds 1800
if errorlevel 1 (
  echo [ERROR] smoke_test.ps1 failed.
  set "RC=1"
  goto :END
)

echo.
echo [OK] Deployment complete.

goto :END


REM =========================================================
REM Helpers
REM =========================================================

:StopTask
REM Usage: call :StopTask "TaskName" "CmdLineLikePattern"
set "TASKNAME=%~1"
set "KILLPAT=%~2"

schtasks /query /tn "%TASKNAME%" >nul 2>&1
if errorlevel 1 (
  echo [INFO] Task not found: %TASKNAME%
  exit /b 0
)

echo [INFO] Stop request: %TASKNAME%
schtasks /end /tn "%TASKNAME%" >nul 2>&1

REM Wait up to 10s for graceful stop
for /l %%I in (1,1,10) do (
  call :IsTaskRunning "%TASKNAME%"
  if errorlevel 1 (
    timeout /t 1 /nobreak >nul
  ) else (
    echo [INFO] Task stopped: %TASKNAME%
    exit /b 0
  )
)

REM Hard-kill fallback (best effort)
if not "%KILLPAT%"=="" (
  echo [WARN] Task still running after stop request: %TASKNAME%
  echo [WARN] Attempting hard-kill of process(es) matching: %KILLPAT%
  call :KillByCmdLine "%KILLPAT%"

  REM Wait up to 10s after kill
  for /l %%I in (1,1,10) do (
    call :IsTaskRunning "%TASKNAME%"
    if errorlevel 1 (
      timeout /t 1 /nobreak >nul
    ) else (
      echo [INFO] Task stopped after hard-kill: %TASKNAME%
      exit /b 0
    )
  )
)

echo [ERROR] Timed out waiting for task to stop: %TASKNAME%
exit /b 1

:IsTaskRunning
REM Returns ERRORLEVEL 1 if running, 0 if not running / not found
schtasks /query /tn "%~1" /fo list | findstr /i /c:"Status: Running" >nul
if errorlevel 1 (
  exit /b 0
) else (
  exit /b 1
)

:KillByCmdLine
REM Uses CIM to find processes by CommandLine wildcard (-like) and taskkill /T /F them.
set "PAT=%~1"
powershell -NoProfile -Command ^
  "$pat = '%PAT%';" ^
  "$procs = Get-CimInstance Win32_Process | Where-Object { $_.CommandLine -and $_.CommandLine -like $pat };" ^
  "if(-not $procs){ exit 0 }" ^
  "foreach($p in $procs){ Write-Host ('[INFO] taskkill /PID ' + $p.ProcessId); & taskkill.exe /PID $p.ProcessId /F /T | Out-Null }"
exit /b 0


REM =========================================================
REM End
REM =========================================================
:END
echo.
echo Deployment exit code: %RC%
pause
exit /b %RC%
exit /b %RC%