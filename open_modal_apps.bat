@echo off
setlocal

set PYTHONIOENCODING=utf-8
set PYTHONUTF8=1

for /f "usebackq delims=" %%W in (`powershell -NoProfile -ExecutionPolicy Bypass -Command "$env:PYTHONIOENCODING='utf-8'; $env:PYTHONUTF8='1'; $profiles = modal profile list --json | ConvertFrom-Json; $active = $profiles | Where-Object { $_.active } | Select-Object -First 1; if (-not $active) { throw 'No active Modal profile found. Run modal profile list or modal setup first.' }; $active.workspace"`) do set "MODAL_WORKSPACE=%%W"

if not defined MODAL_WORKSPACE (
  echo Could not find the active Modal workspace.
  exit /b 1
)

set "COMFYUI_URL=https://%MODAL_WORKSPACE%--comfyui.modal.run"
set "JUPYTER_URL=https://%MODAL_WORKSPACE%--jupyter.modal.run/lab?token=modal-comfyui"

echo Opening ComfyUI: %COMFYUI_URL%
start "" "%COMFYUI_URL%"

echo Opening JupyterLab: %JUPYTER_URL%
start "" "%JUPYTER_URL%"
