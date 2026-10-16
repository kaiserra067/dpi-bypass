@echo off
net session >nul 2>&1
if errorlevel 1 (
    powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    exit /b
)
rem Tek satir: uninstall.ps1 bu dosyanin bulundugu klasoru silebilir.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0uninstall.ps1" & echo. & pause & exit /b
