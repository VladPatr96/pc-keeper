@echo off
where pwsh >nul 2>nul
if %ERRORLEVEL%==0 (
  pwsh -NoProfile -ExecutionPolicy Bypass -File "%~dp0program-update-all.ps1" %*
) else (
  powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0program-update-all.ps1" %*
)
exit /b %ERRORLEVEL%
