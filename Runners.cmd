@echo off
rem Double-click me: Windows asks for admin rights once, then the one menu for every runner on this PC (Windows services and Docker containers) lists, adds, removes, cleans up and recovers them, and turns the watchdog on or off.
powershell -NoProfile -Command "Start-Process powershell -Verb RunAs -ArgumentList '-NoProfile -ExecutionPolicy Bypass -File \"%~dp0Runners.ps1\"'"
