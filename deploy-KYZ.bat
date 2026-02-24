@echo off
setlocal EnableExtensions EnableDelayedExpansion

set "DST=C:\apps\kyz-energy-monitor"
set "NPM=npm.cmd"

set "TASK_INGESTOR=KYZ-Ingestor"
set "TASK_DASH=KYZ-Dashboard-API"
set "TASK_RETENTION=KYZ-Live15s-Retention"
set "TASK_MONTHLY=KYZ-MonthlyDemand-Refresh"

set "SRC=%~dp0"
if "%SRC:~-1%"=="\" set "SRC=%SRC:~0,-1%"

set "RC=0"

echo.
echo =========================================================
echo Deploying KYZ Energy Monitor
echo   SRC: %SRC%
echo   DST: %DST%
echo =========================================================
echo.

net session >nul 2>&1
if errorlevel 1 (
  echo [ERROR] Not running as Administrator.
  set "RC=1"
  goto :END
)

if not exist "%SRC%\scripts\windows\install_ingestor.ps1" (
  echo [ERROR] Source path does not look like KYZ repo:
  echo         %SRC%
  set "RC=1"
  goto :END
)

if not exist "%DST%" mkdir "%DST%" >nul 2>&1
if not exist "%DST%\logs" mkdir "%DST%\logs" >nul 2>&1

echo [INFO] Stopping scheduled tasks (if present)...
call :StopAndWait "%TASK_INGESTOR%"
if errorlevel 1 set "RC=1" & goto :END
call :StopAndWait "%TASK_DASH%"
if errorlevel 1 set "RC=1" & goto :END
call :StopAndWait "%TASK_RETENTION%"
if errorlevel 1 set "RC=1" & goto :END
call :StopAndWait "%TASK_MONTHLY%"
if errorlevel 1 set "RC=1" & goto :END

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

:StopAndWait
set "TASKNAME=%~1"
schtasks /query /tn "%TASKNAME%" >nul 2>&1
if errorlevel 1 (
  echo [INFO] Task not found: %TASKNAME%
  exit /b 0
)

schtasks /end /tn "%TASKNAME%" >nul 2>&1
for /l %%I in (1,1,30) do (
  schtasks /query /tn "%TASKNAME%" /fo list /v | findstr /i "Status: Running" >nul
  if errorlevel 1 (
    echo [INFO] Task stopped: %TASKNAME%
    exit /b 0
  )
  timeout /t 1 /nobreak >nul
)

echo [ERROR] Timed out waiting for task to stop: %TASKNAME%
exit /b 1

:END
echo.
echo Deployment exit code: %RC%
pause
exit /b %RC%
