@echo off
rem Double-click me: Windows asks for admin rights once (Defender changes need them), then a menu
rem adds, shows and removes the Microsoft Defender exclusions that keep runner builds fast.
powershell -NoProfile -Command "Start-Process powershell -Verb RunAs -ArgumentList '-NoProfile -ExecutionPolicy Bypass -File \"%~dp0DefenderExclusions.ps1\"'"
