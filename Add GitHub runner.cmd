@echo off
rem Double-click me: Windows asks for admin rights once, then a menu asks which repository gets a runner.
powershell -NoProfile -Command "Start-Process powershell -Verb RunAs -ArgumentList '-NoProfile -ExecutionPolicy Bypass -File \"%~dp0add-runner.ps1\"'"
