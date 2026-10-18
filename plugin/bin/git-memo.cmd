@echo off
rem gitmemo CLI launcher for Windows shells that only resolve .cmd files.
pwsh -NoProfile -File "%~dp0git-memo.ps1" %*
