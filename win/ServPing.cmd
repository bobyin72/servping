@echo off
rem ===========================================================================
rem  ServPing.cmd — double-click entry point for ServPing.ps1
rem  Mirrors Svr2Desktop.cmd: prefer pwsh.exe, fall back to powershell.exe 5.1,
rem  request elevation exactly once, pause only for a real double-click.
rem ===========================================================================

setlocal EnableExtensions
set "SCRIPT=%~dp0%~n0.ps1"
set "ARGS=%*"

if not exist "%SCRIPT%" (
    echo [ERROR] %~n0.ps1 was not found next to this launcher.
    echo         Expected: %SCRIPT%
    echo.
    pause
    exit /b 1
)

set "PSEXE=powershell.exe"
set "PSMODE=Windows PowerShell 5.1"
where pwsh.exe >nul 2>&1
if not errorlevel 1 (
    set "PSEXE=pwsh.exe"
    set "PSMODE=PowerShell 7"
)
where %PSEXE% >nul 2>&1
if errorlevel 1 (
    echo [ERROR] %PSEXE% not found. Windows PowerShell 5.1 is required.
    pause
    exit /b 1
)

rem --- elevation probe: fltmc works without any service ---
fltmc >nul 2>&1
if not errorlevel 1 goto :launch
if defined SVRPING_RUNAS (
    echo [ERROR] still not elevated after requesting UAC. Nothing was changed.
    pause
    exit /b 1
)
echo Administrator privileges are required - requesting elevation...
set "SVRPING_RUNAS=1"
if not "%ARGS%"=="" goto :relaunch_with_args
powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
exit /b
:relaunch_with_args
powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -ArgumentList '%ARGS%' -Verb RunAs"
exit /b

:launch
echo Host: %PSMODE%
echo.
%PSEXE% -NoProfile -NoLogo -ExecutionPolicy Bypass -File "%SCRIPT%" %ARGS%
set "RC=%ERRORLEVEL%"
echo.
if not "%RC%"=="0" echo Script exited with code %RC%.
if not "%ARGS%"=="" goto :done
echo %cmdcmdline% | find /i "%~nx0" >nul
if not errorlevel 1 pause
:done
exit /b %RC%
