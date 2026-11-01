@echo off
rem Double-click me: Windows asks for admin rights once, then a menu lists, adds, removes, cleans up and recovers runners, and turns the watchdog on or off.
powershell -NoProfile -Command "Start-Process powershell -Verb RunAs -ArgumentList '-NoProfile -ExecutionPolicy Bypass -File \"%~dp0Runners.ps1\"'"
