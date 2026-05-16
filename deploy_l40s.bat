@echo off
setlocal

set MODAL_GPU=L40S
set PYTHONIOENCODING=utf-8
set PYTHONUTF8=1

modal deploy modal_app.py
if errorlevel 1 exit /b %errorlevel%
