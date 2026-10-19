@echo off
setlocal EnableExtensions
title PPPoE AutoDial - Uninstall

rem ===================================================================
rem  PPPoE AutoDial - uninstaller
rem  Stops it, disables it, then removes the scheduled task.
rem  Double-click this file. It will ask for administrator rights once.
rem ===================================================================

powershell -NoProfile -ExecutionPolicy Bypass -Command "$p=New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent()); if(-not $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)){exit 1}"
if errorlevel 1 (
    echo.
    echo   This uninstaller needs administrator rights.
    echo   A UAC prompt will appear - please click Yes.
    echo.
    powershell -NoProfile -ExecutionPolicy Bypass -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    exit /b
)

echo.
echo  ============================================================
echo    PPPoE AutoDial  -  uninstall
echo  ============================================================
echo.

set "PS1=%ProgramData%\PPPoEAutoDial\Manage-PPPoEAutoDial.ps1"

if not exist "%PS1%" (
    echo   Installed copy not found at:
    echo     %PS1%
    echo   Falling back to the copy next to this uninstaller...
    set "PS1=%~dp0Manage-PPPoEAutoDial.ps1"
)

powershell -NoProfile -ExecutionPolicy Bypass -File "%PS1%" -Panic    >nul 2>&1
powershell -NoProfile -ExecutionPolicy Bypass -File "%PS1%" -Uninstall
set "RC=%ERRORLEVEL%"

echo.
echo   The scheduled task has been removed.
echo   Logs and settings were intentionally kept at:
echo     %ProgramData%\PPPoEAutoDial
echo   Delete that folder yourself if you want them gone too.
echo.
pause
exit /b %RC%
