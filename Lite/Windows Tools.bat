@echo off
rem MacTools Lite - Windows diagnostics. Double-click to open the menu.
rem Uses only PowerShell built into Windows; nothing is installed.
rem Right-click > "Run as administrator" for disk health and the full startup list.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Tools\WinTools.ps1"
if errorlevel 1 pause
