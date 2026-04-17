@echo off
powershell.exe -ExecutionPolicy Bypass -NonInteractive -NoProfile -File "C:\streaming-backend\scripts\relay.ps1" -StreamPath %1
