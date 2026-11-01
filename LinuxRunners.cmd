@echo off
rem Double-click me: a menu shows, adds, removes, adopts and recovers Linux runners in Docker Desktop, and turns the watchdog on or off. No admin rights needed.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0LinuxRunners.ps1" %*
