@echo off
setlocal EnableExtensions EnableDelayedExpansion

REM =========================================================
REM  KYZ Energy Monitor - Deploy
REM  - Mirrors repo (folder containing this .bat) to C:\apps\kyz-energy-monitor
REM  - Preserves: .env, venvs, logs, node_modules, built assets
REM  - Runs installer PS1 scripts
REM  - Forces dashboard build + copies dist -> api\static
REM  - Creates/updates scheduled tasks (SYSTEM) + starts them
REM  - PAUSES on success and failure (no more "auto-close")
REM =========================================================

REM ----- CONFIG -----
set "DST=C:\apps\kyz-energy-monitor"
set "NPM=npm.cmd"

REM Your actual task names:
set "TASK_INGESTOR=KYZ-Ingestor"
set "TASK_DASH=KYZ-Dashboard-API"
set "TASK_RETENTION=KYZ-Live15s-Retention"

REM Repo root = folder containing this BAT
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

REM ----- ADMIN CHECK (Task Scheduler needs it) -----
net session >nul 2>&1
if errorlevel 1 (
  echo [ERROR] Not running as Administrator.
  echo         Right-click this .bat ^> Run as administrator
  set "RC=1"
  goto :END
)

REM ----- SANITY CHECK -----
if not exist "%SRC%\scripts\windows\install_ingestor.ps1" (
  echo [ERROR] Source path does not look like KYZ repo:
  echo         %SRC%
  set "RC=1"
  goto :END
)

REM ----- ENSURE DST -----
if not exist "%DST%" mkdir "%DST%" >nul 2>&1
if not exist "%DST%\logs" mkdir "%DST%\logs" >nul 2>&1

REM ----- STOP TASKS (ignore errors) -----
echo [INFO] Stopping scheduled tasks (ignore errors)...
schtasks /end /tn "%TASK_DASH%" >nul 2>&1
schtasks /end /tn "%TASK_INGESTOR%" >nul 2>&1
schtasks /end /tn "%TASK_RETENTION%" >nul 2>&1

REM ----- MIRROR REPO -> DST (preserve runtime artifacts) -----
echo.
echo [INFO] Mirroring repo to live folder (preserving env/venvs/logs/node_modules/static)...
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

REM ----- INSTALL/VERIFY INGESTOR -----
echo.
echo [INFO] Running install_ingestor.ps1...
powershell -NoProfile -ExecutionPolicy Bypass -File "%DST%\scripts\windows\install_ingestor.ps1" -RepoRoot "%DST%" -PythonExe "python"
if errorlevel 1 (
  echo [ERROR] install_ingestor.ps1 failed.
  set "RC=1"
  goto :END
)

REM ----- INSTALL/VERIFY DASHBOARD (PS1) -----
echo.
echo [INFO] Running install_dashboard.ps1...
powershell -NoProfile -ExecutionPolicy Bypass -File "%DST%\scripts\windows\install_dashboard.ps1" -RepoRoot "%DST%" -PythonExe "python" -NodeExe "%NPM%"
if errorlevel 1 (
  echo [ERROR] install_dashboard.ps1 failed.
  set "RC=1"
  goto :END
)

REM ----- FORCE FRONTEND BUILD + COPY DIST -> STATIC (the thing you keep missing) -----
echo.
echo [INFO] Forcing dashboard frontend build + static publish...
pushd "%DST%\dashboard\web" >nul 2>&1
if errorlevel 1 (
  echo [ERROR] Missing folder: %DST%\dashboard\web
  set "RC=1"
  goto :END
)

if not exist "node_modules" (
  echo [INFO] node_modules missing -> npm install
  call %NPM% install
  if errorlevel 1 (
    echo [ERROR] npm install failed
    popd >nul 2>&1
    set "RC=1"
    goto :END
  )
)

call %NPM% run build
if errorlevel 1 (
  echo [ERROR] npm run build failed
  popd >nul 2>&1
  set "RC=1"
  goto :END
)
popd >nul 2>&1

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

REM ----- CREATE/UPDATE TASKS + START -----
echo.
echo [INFO] Registering/updating Scheduled Tasks + starting them...
powershell -NoProfile -ExecutionPolicy Bypass -File "%DST%\scripts\windows\create_taskscheduler_jobs.ps1" -RepoRoot "%DST%" -TaskUser "SYSTEM" -RetentionDays 7 -RunNow
if errorlevel 1 (
  echo [ERROR] create_taskscheduler_jobs.ps1 failed
  set "RC=1"
  goto :END
)

REM ----- OPTIONAL: SMOKE TEST -----
echo.
echo [INFO] Running smoke test...
powershell -NoProfile -ExecutionPolicy Bypass -File "%DST%\scripts\windows\smoke_test.ps1" -BaseUrl "http://localhost:8080" -FreshnessThresholdSeconds 1800
if errorlevel 1 (
  echo [WARNING] smoke_test.ps1 failed (not fatal to deploy)
)

echo.
echo [OK] Deployment complete.

:END
echo.
echo Deployment exit code: %RC%
pause
exit /b %RC%