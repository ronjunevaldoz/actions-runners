@echo off
rem Runners.cmd is the main menu; this one still works. Double-click me: a menu shows, adds, removes, adopts and recovers Linux runners in Docker Desktop, and turns the watchdog on or off. No admin rights needed.
echo Runners.cmd is the main menu now: it manages these Docker runners and the Windows-service runners together.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0LinuxRunners.ps1" %*
