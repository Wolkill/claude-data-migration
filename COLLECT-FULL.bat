@echo off
chcp 65001 >nul
setlocal

rem ============================================================
rem  Полный сбор ПЕРЕД ФОРМАТИРОВАНИЕМ старой машины:
rem  история Claude + сами рабочие папки проектов.
rem  Может получиться крупный архив — это нормально.
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
echo   Сначала посчитаю объём, ничего не копируя...
echo.

%PY% collect_claude.py --dry-run --include-workdirs

echo.
echo ============================================================
set "ANSWER="
set /p "ANSWER=  Собирать? Введи ДА и нажми Enter (любой другой ответ - отмена): "

if /i not "%ANSWER%"=="ДА" (
    echo.
    echo   Отменено.
    echo.
    pause
    exit /b 0
)

echo.
%PY% collect_claude.py --zip --include-workdirs %*

echo.
echo ============================================================
echo   Готово. Перенеси claude-evac.zip на новый компьютер
echo   И НЕ ФОРМАТИРУЙ старую машину, пока не проверишь,
echo   что на новой всё открывается.
echo ============================================================
echo.
pause
