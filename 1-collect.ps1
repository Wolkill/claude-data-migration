<#
  ШАГ 1 — СБОР. Запускать НА СТАРОМ КОМПЬЮТЕРЕ.
  (или на этом, указав -SourceProfile для подключённого диска старой машины)

  Собирает только ценное: транскрипты, настройки, MCP-конфиги, сессии Cowork.
  Кэши, токены и бинарники не трогает.

  Примеры:
    .\1-collect.ps1
    .\1-collect.ps1 -SourceProfile "E:\Users\Ivan" -OutDir "E:\claude-evac"
    .\1-collect.ps1 -Zip
#>
[CmdletBinding()]
param(
    # Корень профиля-источника. По умолчанию — текущий пользователь.
    [string]$SourceProfile = $env:USERPROFILE,

    # Куда складывать. По умолчанию — папка claude-evac рядом со скриптом.
    [string]$OutDir,

    # Упаковать результат в .zip
    [switch]$Zip
)

$ErrorActionPreference = 'Stop'

# Каталог скрипта. В блоке param $PSScriptRoot ещё пуст, если PowerShell
# запущен как  -File <относительный путь>  — поэтому определяем здесь.
$scriptDir = $PSScriptRoot
if (-not $scriptDir) { $scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition }
if (-not $scriptDir) { $scriptDir = (Get-Location).Path }

if (-not $OutDir) { $OutDir = Join-Path $scriptDir 'claude-evac' }

if (-not (Test-Path $SourceProfile)) { throw "Не найден профиль: $SourceProfile" }

$srcClaude  = Join-Path $SourceProfile '.claude'
$srcJson    = Join-Path $SourceProfile '.claude.json'
$srcRoaming = Join-Path $SourceProfile 'AppData\Roaming\Claude'

Write-Host "Источник : $SourceProfile" -ForegroundColor Cyan
Write-Host "Приёмник : $OutDir"        -ForegroundColor Cyan
Write-Host ''

if (-not (Test-Path $OutDir)) { New-Item -ItemType Directory -Path $OutDir -Force | Out-Null }
New-Item -ItemType Directory -Path (Join-Path $OutDir 'claude')  -Force | Out-Null
New-Item -ItemType Directory -Path (Join-Path $OutDir 'roaming') -Force | Out-Null

function Copy-Item-Safe {
    param([string]$From, [string]$To, [string]$Label)

    if (-not (Test-Path $From)) {
        Write-Host ("  -   {0,-34} нет" -f $Label) -ForegroundColor DarkGray
        return
    }
    $parent = Split-Path $To -Parent
    if (-not (Test-Path $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }

    Copy-Item -Path $From -Destination $To -Recurse -Force

    $stat = Get-ChildItem $To -Recurse -Force -File -ErrorAction SilentlyContinue |
            Measure-Object -Property Length -Sum
    Write-Host ("  OK  {0,-34} {1,6} файл(ов)  {2,8:N1} МБ" -f $Label, $stat.Count, ($stat.Sum/1MB)) -ForegroundColor Green
}

# --- Claude Code: ~\.claude ---------------------------------------------
Write-Host 'Claude Code (~\.claude):' -ForegroundColor Yellow

# ГЛАВНОЕ: все транскрипты диалогов + memory-папки проектов
Copy-Item-Safe (Join-Path $srcClaude 'projects') (Join-Path $OutDir 'claude\projects') 'projects (транскрипты)'

foreach ($name in @('history.jsonl','settings.json','CLAUDE.md','keybindings.json','MEMORY.md')) {
    Copy-Item-Safe (Join-Path $srcClaude $name) (Join-Path $OutDir "claude\$name") $name
}
foreach ($name in @('plugins','backups','todos','agents','commands','skills','hooks','memory')) {
    Copy-Item-Safe (Join-Path $srcClaude $name) (Join-Path $OutDir "claude\$name") $name
}

# --- Глобальный конфиг ---------------------------------------------------
Write-Host ''
Write-Host 'Глобальный конфиг:' -ForegroundColor Yellow
Copy-Item-Safe $srcJson (Join-Path $OutDir 'claude.json') '.claude.json'

# --- Claude Desktop: %APPDATA%\Claude ------------------------------------
Write-Host ''
Write-Host 'Claude Desktop (%APPDATA%\Claude):' -ForegroundColor Yellow
foreach ($name in @('claude_desktop_config.json','config.json','git-worktrees.json')) {
    Copy-Item-Safe (Join-Path $srcRoaming $name) (Join-Path $OutDir "roaming\$name") $name
}
foreach ($name in @('local-agent-mode-sessions','claude-code-sessions')) {
    Copy-Item-Safe (Join-Path $srcRoaming $name) (Join-Path $OutDir "roaming\$name") $name
}

# --- Опись рабочих папок проектов ----------------------------------------
# Имя папки в .claude\projects — это путь, где ВСЁ кроме букв и цифр заменено на '-':
#   C:\Projects\my-app     -> C--Projects-my-app
#   D:\work\demo_service   -> D--work-demo-service   ('_' тоже становится '-')
# Обратное преобразование неоднозначно, поэтому настоящие пути берём из .claude.json.
$projDir = Join-Path $OutDir 'claude\projects'
if (Test-Path $projDir) {

    function ConvertTo-ProjectFolderName {
        param([string]$Path)
        # то же правило кодирования, что и у Claude Code
        return ($Path -replace '[^A-Za-z0-9]', '-')
    }

    # словарь: имя_папки -> реальный путь (из ключей projects в .claude.json)
    $pathByFolder = @{}
    $cfgCopy = Join-Path $OutDir 'claude.json'
    if (Test-Path $cfgCopy) {
        try {
            $cfg = Get-Content $cfgCopy -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($cfg.projects) {
                foreach ($key in $cfg.projects.PSObject.Properties.Name) {
                    $folder = ConvertTo-ProjectFolderName $key
                    # предпочитаем вариант с обратными слэшами (канонический для Windows)
                    if ((-not $pathByFolder.ContainsKey($folder)) -or ($key -like '*\*')) {
                        $pathByFolder[$folder] = $key
                    }
                }
            }
        } catch {
            Write-Host "  (не удалось разобрать .claude.json: $_)" -ForegroundColor DarkYellow
        }
    }

    $report = Get-ChildItem $projDir -Directory | ForEach-Object {
        $n = $_.Name

        if ($pathByFolder.ContainsKey($n)) {
            $path   = $pathByFolder[$n]
            $source = 'config'
        } else {
            # запасной вариант — приблизительная реконструкция, требует проверки глазами
            $path   = ($n -replace '^([A-Za-z])--', '$1:\') -replace '-', '\'
            $source = 'ПРОВЕРЬ'
        }

        $sessions = @(Get-ChildItem $_.FullName -Filter *.jsonl -File -ErrorAction SilentlyContinue).Count
        [pscustomobject]@{
            Folder      = $n
            ProjectPath = $path
            PathSource  = $source
            Sessions    = $sessions
            ExistsHere  = (Test-Path $path)
        }
    }

    $report | Format-Table -AutoSize | Out-String -Width 200 | Write-Host

    # --- Проектные скиллы/агенты/команды --------------------------------
    # Лежат ВНУТРИ рабочей папки проекта, а не в профиле, поэтому иначе
    # уехали бы только вместе со всем проектом. Весят мало — берём всегда.
    Write-Host 'Настройки Claude внутри проектов:' -ForegroundColor Yellow
    $cfgNames = @('.claude', 'CLAUDE.md', 'CLAUDE.local.md', '.mcp.json')
    $foundCfg = $false

    foreach ($row in $report) {
        if (-not $row.ExistsHere) { continue }

        $picked = 0
        foreach ($name in $cfgNames) {
            $from = Join-Path $row.ProjectPath $name
            if (-not (Test-Path $from)) { continue }

            $to = Join-Path $OutDir "project-configs\$($row.Folder)\$name"
            $parent = Split-Path $to -Parent
            if (-not (Test-Path $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
            Copy-Item -Path $from -Destination $to -Recurse -Force -ErrorAction SilentlyContinue

            $picked += @(Get-ChildItem $to -Recurse -Force -File -ErrorAction SilentlyContinue).Count
        }

        if ($picked -gt 0) {
            $foundCfg = $true
            $skillDir = Join-Path $row.ProjectPath '.claude\skills'
            $extra = ''
            if (Test-Path $skillDir) {
                $sc = @(Get-ChildItem $skillDir -Directory -ErrorAction SilentlyContinue).Count
                if ($sc -gt 0) { $extra = "   [скиллов: $sc]" }
            }
            Write-Host ("  OK  {0,-40} {1,4} файл(ов){2}" -f $row.ProjectPath, $picked, $extra) -ForegroundColor Green
        }
    }
    if (-not $foundCfg) {
        Write-Host '  -   ни в одном проекте нет своих настроек Claude' -ForegroundColor DarkGray
    }

    # --- Карта проектов --------------------------------------------------
    # Формат обязан совпадать с тем, что читает 2-merge.ps1:
    # разделитель ';' и русские заголовки.
    $csvLines = New-Object 'System.Collections.Generic.List[string]'
    $csvLines.Add('Папка;ПутьПроекта;ИсточникПути;Сессий;ЕстьНаДиске;ФайловВПапке;РазмерБайт')
    foreach ($row in $report) {
        $ex = 'нет'; if ($row.ExistsHere) { $ex = 'да' }
        $csvLines.Add(('{0};{1};{2};{3};{4};0;0' -f $row.Folder, $row.ProjectPath, $row.PathSource, $row.Sessions, $ex))
    }
    $utf8Bom = New-Object System.Text.UTF8Encoding($true)
    [System.IO.File]::WriteAllLines((Join-Path $OutDir 'projects-map.csv'), $csvLines, $utf8Bom)

    Write-Host ''
    Write-Host 'Карта проектов -> projects-map.csv' -ForegroundColor Cyan
    Write-Host 'ВАЖНО: рабочие папки из ProjectPath перенеси на новый ПК по ТЕМ ЖЕ путям,' -ForegroundColor Magenta
    Write-Host '       иначе история диалогов к ним не привяжется.' -ForegroundColor Magenta
    if ($report | Where-Object { $_.PathSource -eq 'ПРОВЕРЬ' }) {
        Write-Host 'Для строк с PathSource=ПРОВЕРЬ путь восстановлен приблизительно — сверь вручную.' -ForegroundColor DarkYellow
    }
}

# --- Упаковка ------------------------------------------------------------
if ($Zip) {
    $zipPath = "$OutDir.zip"
    if (Test-Path $zipPath) { Remove-Item $zipPath -Force }
    Compress-Archive -Path (Join-Path $OutDir '*') -DestinationPath $zipPath -CompressionLevel Optimal
    Write-Host ''
    Write-Host ("Архив: {0}  ({1:N1} МБ)" -f $zipPath, ((Get-Item $zipPath).Length/1MB)) -ForegroundColor Green
}

Write-Host ''
Write-Host 'Готово. Перенеси эту папку на новый ПК и запусти там 2-merge.ps1' -ForegroundColor Green
Write-Host 'Токен .credentials.json НЕ копировался — на новой машине просто войди в аккаунт.' -ForegroundColor DarkYellow
