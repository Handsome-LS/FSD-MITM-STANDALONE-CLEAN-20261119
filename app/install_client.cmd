@echo off
title FSD Client Setup
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0install_client.ps1" %*
echo.
echo Done. Press any key to close.
pause >nul
