@echo off
rem Double-click me: Windows asks for admin rights once, then Add-Runner.ps1 asks which repository gets a runner.
powershell -NoProfile -Command "Start-Process powershell -Verb RunAs -ArgumentList '-NoProfile -NoExit -ExecutionPolicy Bypass -File \"%~dp0Add-Runner.ps1\"'"
