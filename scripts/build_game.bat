@echo off
setlocal
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0build_game.ps1" %*
exit /b %ERRORLEVEL%
