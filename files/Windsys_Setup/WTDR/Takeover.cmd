@echo off
setlocal

if /i "%~1"=="--watch-cmdline" goto watch

>>"%~dp0Takeover.log" echo [%date% %time%] Takeover script started. Working directory: %cd%
rem Keep the watcher running independently while WTDR takes over deployment.
start "" /b "%ComSpec%" /d /c ""%~f0" --watch-cmdline"
>>"%~dp0Takeover.log" echo [%date% %time%] Starting WTDR.exe -Deploy.
"%~dp0WTDR.exe" -Deploy
set "wtdr_exit=%errorlevel%"
>>"%~dp0Takeover.log" echo [%date% %time%] WTDR.exe returned %wtdr_exit%.
exit /b %wtdr_exit%

:watch
>>"%~dp0Takeover.log" echo [%date% %time%] CmdLine watcher started; waiting 60 seconds.
call :sleep 60
if errorlevel 1 exit /b 1
>>"%~dp0Takeover.log" echo [%date% %time%] CmdLine monitoring started.
:check_cmdline
reg query "HKLM\SYSTEM\Setup" /v CmdLine 2>nul | findstr /i /l /c:"windeploy.exe" >nul
if not errorlevel 1 goto restart
call :sleep 5
if errorlevel 1 exit /b 1
goto check_cmdline

:restart
>>"%~dp0Takeover.log" echo [%date% %time%] windeploy.exe detected; restarting in 5 seconds.
call :sleep 5
if errorlevel 1 exit /b 1
shutdown /r /f /t 0
>>"%~dp0Takeover.log" echo [%date% %time%] shutdown returned %errorlevel%.
exit /b

:sleep
"%SystemRoot%\System32\cscript.exe" //B //NoLogo "%~dp0Sleep.vbs" %~1 >>"%~dp0Takeover.log" 2>&1
if errorlevel 1 (
    >>"%~dp0Takeover.log" echo [%date% %time%] ERROR: sleep failed; watcher stopped.
    exit /b 1
)
exit /b 0
