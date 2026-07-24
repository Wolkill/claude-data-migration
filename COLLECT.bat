@echo off
chcp 65001 >nul
setlocal

rem ============================================================
rem  Запуск сборщика данных Claude двойным кликом.
rem  Класть в ту же папку, что и collect_claude.py.
rem  Работает НА СТАРОМ компьютере — с которого эвакуируемся.
rem ============================================================

cd /d "%~dp0"

set "PY="
where py >nul 2>&1
if %errorlevel%==0 set "PY=py"
if not defined PY (
    where python >nul 2>&1
    if %errorlevel%==0 set "PY=python"
)

if not defined PY (
    echo.
    echo   Python не найден.
    echo   Установи с https://www.python.org/downloads/ ^(галочку "Add to PATH" не снимай^)
    echo   или используй запасной вариант: 1-collect.ps1
    echo.
    pause
    exit /b 1
)

echo.
echo   Интерпретатор: %PY%
echo.

%PY% collect_claude.py --zip %*

echo.
echo ============================================================
echo   Готово. Перенеси claude-evac.zip на новый компьютер.
echo ============================================================
echo.
pause
