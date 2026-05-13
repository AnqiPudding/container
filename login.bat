@echo off
setlocal

modal token new --profile current-browser --activate
modal profile current
modal profile list
