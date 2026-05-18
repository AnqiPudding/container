@echo off
setlocal

set "ROOT=%~dp0"
set "URL=http://127.0.0.1:8787"

cd /d "%ROOT%"

start "Comfy Control Web" powershell -NoExit -NoProfile -ExecutionPolicy Bypass -File "%ROOT%control_web\run_local.ps1"

echo Starting Comfy Control Web...
powershell -NoProfile -ExecutionPolicy Bypass -Command ^
  "$url = '%URL%';" ^
  "$deadline = (Get-Date).AddMinutes(3);" ^
  "while ((Get-Date) -lt $deadline) {" ^
  "  try { Invoke-WebRequest -UseBasicParsing -TimeoutSec 2 $url | Out-Null; exit 0 } catch { Start-Sleep -Seconds 2 }" ^
  "}" ^
  "exit 1"

if errorlevel 1 (
  echo The server did not respond yet. Opening the URL anyway.
) else (
  echo Control web app is ready.
)

start "" "%URL%"

endlocal
