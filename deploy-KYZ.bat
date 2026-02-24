@echo off
setlocal

set "SRC=%~dp0"
if "%SRC:~-1%"=="\" set "SRC=%SRC:~0,-1%"
set "DST=C:\apps\kyz-energy-monitor"

if not exist "%SRC%\scripts\windows\install_ingestor.ps1" (
  echo [ERROR] Source path does not look like KYZ repo: %SRC%
  set "RC=1"
  goto :end
)

if not exist "%DST%" mkdir "%DST%"
if not exist "%DST%\logs" mkdir "%DST%\logs"

echo [INFO] Mirroring %SRC% to %DST% (preserving env, venvs, logs, node_modules, and built static assets)...
robocopy "%SRC%" "%DST%" /MIR /R:2 /W:2 /NFL /NDL /NJH /NJS /NP ^
  /XD ".git" ".venv" "dashboard\api\.venv" "dashboard\web\node_modules" "logs" "dashboard\web\dist" "dashboard\api\static" ^
  /XF ".env"
set "ROBO=%ERRORLEVEL%"
if %ROBO% GEQ 8 (
  echo [ERROR] Robocopy failed with code %ROBO%
  set "RC=%ROBO%"
  goto :end
)

powershell -NoProfile -ExecutionPolicy Bypass -File "%DST%\scripts\windows\install_ingestor.ps1"
if errorlevel 1 (
  echo [ERROR] install_ingestor.ps1 failed.
  set "RC=1"
  goto :end
)

powershell -NoProfile -ExecutionPolicy Bypass -File "%DST%\scripts\windows\install_dashboard.ps1"
if errorlevel 1 (
  echo [ERROR] install_dashboard.ps1 failed.
  set "RC=1"
  goto :end
)

if not exist "%DST%\dashboard\api\static\index.html" (
  echo [ERROR] dashboard\api\static\index.html is missing after deployment.
  set "RC=1"
  goto :end
)

powershell -NoProfile -ExecutionPolicy Bypass -File "%DST%\scripts\windows\create_taskscheduler_jobs.ps1" -RunNow
if errorlevel 1 (
  echo [ERROR] create_taskscheduler_jobs.ps1 -RunNow failed.
  set "RC=1"
  goto :end
)

echo [OK] Deployment complete.
set "RC=0"

:end
echo.
echo Deployment exit code: %RC%
pause
exit /b %RC%
