@echo off
chcp 65001 >nul
setlocal

rem ============================================================
rem  ШАГ 1 на новой машине: разложить рабочие папки проектов
rem  из архива по их настоящим путям.
rem  Запускать ПОСЛЕ распаковки claude-evac.zip и ДО MERGE.bat.
rem ============================================================

cd /d "%~dp0"

if not exist "claude-evac" (
    echo.
    echo   Папка claude-evac не найдена.
    echo.
    echo   Распакуй сюда claude-evac.zip со старой машины, чтобы получилось:
    echo       %~dp0claude-evac\projects-map.csv
    echo.
    pause
    exit /b 1
)

set "PY="
where py >nul 2>&1
if %errorlevel%==0 set "PY=py"
if not defined PY (
    where python >nul 2>&1
    if %errorlevel%==0 set "PY=python"
)

if not defined PY (
    echo.
    echo   Python не найден. Установи с https://www.python.org/downloads/
    echo.
    pause
    exit /b 1
)

echo.
echo ============================================================
echo   ШАГ 1 из 2: пробный прогон ^(ничего не записывается^)
echo ============================================================
echo.

%PY% restore_projects.py --dry-run
if errorlevel 1 (
    echo.
    pause
    exit /b 1
)

echo.
echo ============================================================
set "ANSWER="
set /p "ANSWER=  Раскладывать? Введи ДА и нажми Enter (любой другой ответ - отмена): "

if /i not "%ANSWER%"=="ДА" (
    echo.
    echo   Отменено. Ничего не изменено.
    echo.
    pause
    exit /b 0
)

echo.
%PY% restore_projects.py
set "RC=%errorlevel%"

echo.
if not "%RC%"=="0" (
    echo   Раскладывание завершилось с ошибкой — см. выше.
    echo.
    pause
    exit /b %RC%
)

echo ============================================================
echo   Готово. Теперь ПОЛНОСТЬЮ закрой Claude ^(включая трей^)
echo   и запусти  MERGE.bat
echo ============================================================
echo.
pause
