@echo off
rem HTML Wallpaper Loader - zero-install desktop edition
rem -STA is required for the WinForms tray icon; -WindowStyle Hidden hides the console.
powershell -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File "%~dp0wallpaper.ps1"
