@echo off
chcp 65001 >nul
title 内蒙古高考志愿智能推荐 - 本地数据服务
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0server.ps1"
pause
