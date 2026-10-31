@echo off
rem Double-click me: a menu shows, adds, removes and adopts Linux runners in Docker Desktop. No admin rights needed.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0LinuxRunners.ps1" %*
