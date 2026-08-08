@echo off
title Claude Code Multi-Provider - Installer
echo ============================================================
echo   Claude Code Multi-Provider - installer
echo   Sets DeepSeek as default, adds Desktop icons + Manager app.
echo   Your API keys are NOT entered here - you paste them later.
echo ============================================================
echo.
powershell -NoProfile -ExecutionPolicy Bypass -Sta -File "%~dp0install-claude-code-providers.ps1"
echo.
echo You can close this window now.
pause
