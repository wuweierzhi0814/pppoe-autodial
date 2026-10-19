@echo off
setlocal EnableExtensions
title PPPoE AutoDial - Install

rem ===================================================================
rem  PPPoE AutoDial - one-click installer for Windows 10 / 11
rem  Double-click this file. It will ask for administrator rights once.
rem
rem  Optional: pass switches through, e.g.
rem      install.bat -ConnectionName "Broadband Connection"
rem      install.bat -RunLevelHighest
rem ===================================================================

rem ---- step 1: make sure we are elevated ---------------------------
powershell -NoProfile -ExecutionPolicy Bypass -Command "$p=New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent()); if(-not $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)){exit 1}"
if errorlevel 1 (
    echo.
    echo   This installer needs administrator rights.
    echo   A UAC prompt will appear - please click Yes.
    echo.
    powershell -NoProfile -ExecutionPolicy Bypass -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    exit /b
)

echo.
echo  ============================================================
echo    PPPoE AutoDial  -  install
echo  ============================================================
echo.
echo   What it does:
echo     Dials your PPPoE broadband automatically after logon,
echo     after wake-from-sleep, and whenever the link drops.
echo     Every run is bounded: max 10 attempts, 8 minute retry
echo     window, 25 minute process cap, 30 minute OS hard kill.
echo     It never dials while a session is already up, and it
echo     leaves another working internet path alone.
echo.

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Manage-PPPoEAutoDial.ps1" -Install -WithResumeTrigger -WithDropTrigger %*
set "RC=%ERRORLEVEL%"

echo.
if "%RC%"=="0" (
    echo   [OK] Installation finished.
    echo.
    echo   Verify at any time with:
    echo     "%ProgramData%\PPPoEAutoDial\Manage-PPPoEAutoDial.ps1" -TaskStatus
    echo   or:
    echo     schtasks /query /tn PPPoEAutoDial /v /fo LIST
) else (
    echo   [FAILED] installer exit code = %RC%
)
echo.
pause
exit /b %RC%
