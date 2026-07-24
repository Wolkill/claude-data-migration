<#
  ШАГ 2 — СЛИЯНИЕ. Запускать НА ЭТОМ (новом) КОМПЬЮТЕРЕ.

  Вливает собранные данные, НЕ затирая то, что уже есть здесь:
    - транскрипты (.jsonl) добавляются только те, которых нет (имена = UUID, коллизий не будет)
    - history.jsonl склеивается с дедупликацией
    - .claude.json: подмешиваются ТОЛЬКО записи projects; userID/oauthAccount/machineID не трогаются
    - claude_desktop_config.json НЕ перезаписывается — показывается разница

  Перед запуском ОБЯЗАТЕЛЬНО закрыть Claude полностью (иначе он перезапишет .claude.json из памяти).

  Примеры:
    .\2-merge.ps1 -DryRun          # посмотреть, что будет сделано
    .\2-merge.ps1                  # выполнить
#>
[CmdletBinding()]
param(
    # Папка, созданная сборщиком (по умолчанию claude-evac рядом со скриптом)
    [string]$EvacDir,

    # Только показать план, ничего не менять
    [switch]$DryRun,

    # Пропустить проверку запущенного Claude (не рекомендуется)
    [switch]$Force
)

$ErrorActionPreference = 'Stop'

# Каталог скрипта. В блоке param $PSScriptRoot ещё пуст, если PowerShell
# запущен как  -File <относительный путь>  — поэтому определяем здесь.
$scriptDir = $PSScriptRoot
if (-not $scriptDir) { $scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition }
if (-not $scriptDir) { $scriptDir = (Get-Location).Path }

if (-not $EvacDir) { $EvacDir = Join-Path $scriptDir 'claude-evac' }

if (-not (Test-Path $EvacDir)) { throw "Не найдена папка с данными: $EvacDir" }

$dstClaude  = Join-Path $env:USERPROFILE '.claude'
$dstJson    = Join-Path $env:USERPROFILE '.claude.json'
$dstRoaming = Join-Path $env:APPDATA     'Claude'

# --- 0. Claude должен быть закрыт ---------------------------------------
$running = @(Get-Process -Name '*claude*' -ErrorAction SilentlyContinue)
if ($running.Count -gt 0 -and -not $Force -and -not $DryRun) {
    Write-Host 'Claude сейчас запущен:' -ForegroundColor Red
    $running | Select-Object Id, Name, Path | Format-Table -AutoSize | Out-String -Width 200 | Write-Host
    Write-Host 'Закрой приложение полностью (включая иконку в трее) и запусти скрипт снова.' -ForegroundColor Red
    Write-Host 'Иначе Claude при выходе перезапишет .claude.json своей версией из памяти.' -ForegroundColor Red
    exit 2
}

$mode = 'ВЫПОЛНЕНИЕ'
if ($DryRun) { $mode = 'ПРОБНЫЙ ПРОГОН (ничего не меняется)' }
Write-Host "Режим: $mode" -ForegroundColor Cyan
Write-Host ''

# --- 1. Бэкап текущего состояния ----------------------------------------
$stamp     = Get-Date -Format 'yyyy-MM-dd_HH-mm-ss'
$backupDir = Join-Path $scriptDir "backup-before-merge_$stamp"

if (-not $DryRun) {
    New-Item -ItemType Directory -Path $backupDir -Force | Out-Null
    if (Test-Path $dstJson)   { Copy-Item $dstJson (Join-Path $backupDir 'claude.json') -Force }
    if (Test-Path $dstClaude) {
        # бэкапим только ценное, без кэшей
        New-Item -ItemType Directory -Path (Join-Path $backupDir 'claude') -Force | Out-Null
        foreach ($n in @('projects','history.jsonl','settings.json','plugins','backups')) {
            $p = Join-Path $dstClaude $n
            if (Test-Path $p) { Copy-Item $p (Join-Path $backupDir "claude\$n") -Recurse -Force }
        }
    }
    Write-Host "Бэкап текущего состояния: $backupDir" -ForegroundColor Green
    Write-Host ''
}

# --- 2. Транскрипты диалогов --------------------------------------------
Write-Host 'Транскрипты (.claude\projects):' -ForegroundColor Yellow

$srcProjects = Join-Path $EvacDir 'claude\projects'
$added = 0; $skipped = 0; $newProjects = 0

if (Test-Path $srcProjects) {
    foreach ($proj in Get-ChildItem $srcProjects -Directory) {
        $target = Join-Path $dstClaude "projects\$($proj.Name)"
        $isNew  = -not (Test-Path $target)
        if ($isNew) { $newProjects++ }

        $projAdded = 0
        foreach ($f in Get-ChildItem $proj.FullName -Recurse -File) {
            $rel = $f.FullName.Substring($proj.FullName.Length).TrimStart('\')
            $to  = Join-Path $target $rel

            if (Test-Path $to) { $skipped++; continue }   # уже есть — не трогаем

            if (-not $DryRun) {
                $parent = Split-Path $to -Parent
                if (-not (Test-Path $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
                Copy-Item $f.FullName $to -Force
            }
            $added++; $projAdded++
        }

        $tag = '  '
        if ($isNew) { $tag = 'NEW' }
        if ($projAdded -gt 0) {
            Write-Host ("  {0} {1,-40} +{2} файл(ов)" -f $tag, $proj.Name, $projAdded) -ForegroundColor Green
        }
    }
    Write-Host ("  Итого: добавлено {0}, пропущено (уже есть) {1}, новых проектов {2}" -f $added, $skipped, $newProjects)
} else {
    Write-Host '  нет данных' -ForegroundColor DarkGray
}

# --- 2б. Прочее содержимое ~\.claude: скиллы, агенты, команды и т.п. -----
# Транскрипты уже обработаны выше; здесь всё остальное, что собрал сборщик.
# settings.json намеренно не трогаем — он у каждой машины свой.
Write-Host ''
Write-Host 'Личные скиллы, агенты, команды:' -ForegroundColor Yellow

$extraDirs  = @('skills','agents','commands','todos','hooks','memory','backups','plugins')
$extraFiles = @('CLAUDE.md','MEMORY.md','keybindings.json')
$extraTotal = 0

foreach ($n in $extraDirs) {
    $from = Join-Path $EvacDir "claude\$n"
    if (-not (Test-Path $from)) { continue }

    $cnt = 0; $have = 0
    foreach ($f in Get-ChildItem $from -Recurse -File) {
        $rel = $f.FullName.Substring($from.Length).TrimStart('\')
        $to  = Join-Path $dstClaude "$n\$rel"
        if (Test-Path $to) { $have++; continue }

        if (-not $DryRun) {
            $parent = Split-Path $to -Parent
            if (-not (Test-Path $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
            Copy-Item $f.FullName $to -Force
        }
        $cnt++
    }

    $extraTotal += $cnt
    if ($cnt -gt 0) {
        Write-Host ("  OK  {0,-16} +{1} файл(ов)" -f $n, $cnt) -ForegroundColor Green
    } else {
        Write-Host ("  ·   {0,-16} всё уже на месте ({1})" -f $n, $have) -ForegroundColor DarkGray
    }
}

foreach ($n in $extraFiles) {
    $from = Join-Path $EvacDir "claude\$n"
    if (-not (Test-Path $from)) { continue }
    $to = Join-Path $dstClaude $n
    if (Test-Path $to) {
        Write-Host ("  ·   {0,-16} здесь уже есть свой — не трогаю" -f $n) -ForegroundColor DarkGray
    } else {
        if (-not $DryRun) { Copy-Item $from $to -Force }
        $extraTotal++
        Write-Host ("  OK  {0,-16} скопирован" -f $n) -ForegroundColor Green
    }
}

# settings.json: сообщаем о расхождении, но не перезаписываем
$srcSet = Join-Path $EvacDir 'claude\settings.json'
$dstSet = Join-Path $dstClaude 'settings.json'
if ((Test-Path $srcSet) -and (Test-Path $dstSet)) {
    $sa = (Get-Content $srcSet -Raw -Encoding UTF8).Trim()
    $sb = (Get-Content $dstSet -Raw -Encoding UTF8).Trim()
    if ($sa -ne $sb) {
        Write-Host '  ·   settings.json    отличается — оставляю здешний' -ForegroundColor DarkGray
        Write-Host "      старый для сверки: $srcSet" -ForegroundColor DarkGray
    }
} elseif (Test-Path $srcSet) {
    if (-not $DryRun) { Copy-Item $srcSet $dstSet -Force }
    Write-Host '  OK  settings.json    скопирован' -ForegroundColor Green
}

if ($extraTotal -eq 0) {
    Write-Host '  (ничего нового)' -ForegroundColor DarkGray
}

# --- 3. history.jsonl (склейка + дедупликация) --------------------------
Write-Host ''
Write-Host 'history.jsonl:' -ForegroundColor Yellow

$srcHist = Join-Path $EvacDir 'claude\history.jsonl'
$dstHist = Join-Path $dstClaude 'history.jsonl'

if (Test-Path $srcHist) {
    $old = @(); if (Test-Path $dstHist) { $old = @(Get-Content $dstHist -Encoding UTF8) }
    $inc = @(Get-Content $srcHist -Encoding UTF8)

    $seen   = New-Object 'System.Collections.Generic.HashSet[string]'
    $merged = New-Object 'System.Collections.Generic.List[string]'
    foreach ($line in ($inc + $old)) {            # старые записи первыми по времени
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        if ($seen.Add($line)) { $merged.Add($line) }
    }

    Write-Host ("  было {0}, из переноса {1}, после слияния {2}" -f $old.Count, $inc.Count, $merged.Count)
    if (-not $DryRun) {
        $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
        [System.IO.File]::WriteAllLines($dstHist, $merged, $utf8NoBom)
        Write-Host '  записано' -ForegroundColor Green
    }
} else {
    Write-Host '  нет данных' -ForegroundColor DarkGray
}

# --- 4. .claude.json — только ключ projects ------------------------------
Write-Host ''
Write-Host '.claude.json (записи projects):' -ForegroundColor Yellow

$srcCfg = Join-Path $EvacDir 'claude.json'

if ((Test-Path $srcCfg) -and (Test-Path $dstJson)) {
    $src = Get-Content $srcCfg -Raw -Encoding UTF8 | ConvertFrom-Json
    $dst = Get-Content $dstJson -Raw -Encoding UTF8 | ConvertFrom-Json

    $addedKeys = @()
    if ($src.projects) {
        foreach ($p in $src.projects.PSObject.Properties) {
            if ($dst.projects.PSObject.Properties.Name -contains $p.Name) { continue }
            $addedKeys += $p.Name
            if (-not $DryRun) {
                $dst.projects | Add-Member -NotePropertyName $p.Name -NotePropertyValue $p.Value -Force
            }
        }
    }

    if ($addedKeys.Count -eq 0) {
        Write-Host '  новых проектов нет' -ForegroundColor DarkGray
    } else {
        foreach ($k in $addedKeys) { Write-Host "  + $k" -ForegroundColor Green }

        if (-not $DryRun) {
            $json      = $dst | ConvertTo-Json -Depth 100 -Compress:$false
            $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
            $tmp       = "$dstJson.tmp"
            [System.IO.File]::WriteAllText($tmp, $json, $utf8NoBom)

            # проверка: файл должен парситься и сохранить ключевые поля
            try {
                $check = Get-Content $tmp -Raw -Encoding UTF8 | ConvertFrom-Json
                if (-not $check.userID) { throw 'потерян userID' }
                Move-Item $tmp $dstJson -Force
                Write-Host '  записано и проверено' -ForegroundColor Green
            } catch {
                Remove-Item $tmp -Force -ErrorAction SilentlyContinue
                Write-Host "  ОШИБКА, файл не изменён: $_" -ForegroundColor Red
                Write-Host "  Бэкап: $backupDir\claude.json" -ForegroundColor Red
            }
        }
    }
} else {
    Write-Host '  нет данных' -ForegroundColor DarkGray
}

# --- 5. Сессии Cowork ----------------------------------------------------
Write-Host ''
Write-Host 'Сессии Cowork (%APPDATA%\Claude):' -ForegroundColor Yellow

foreach ($n in @('local-agent-mode-sessions','claude-code-sessions')) {
    $from = Join-Path $EvacDir "roaming\$n"
    if (-not (Test-Path $from)) { Write-Host ("  -   {0}" -f $n) -ForegroundColor DarkGray; continue }

    $cnt = 0
    foreach ($f in Get-ChildItem $from -Recurse -File) {
        $rel = $f.FullName.Substring($from.Length).TrimStart('\')
        $to  = Join-Path $dstRoaming "$n\$rel"
        if (Test-Path $to) { continue }
        if (-not $DryRun) {
            $parent = Split-Path $to -Parent
            if (-not (Test-Path $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
            Copy-Item $f.FullName $to -Force
        }
        $cnt++
    }
    Write-Host ("  OK  {0,-28} +{1} файл(ов)" -f $n, $cnt) -ForegroundColor Green
}

# --- 6. Конфиг десктопа: показать разницу, не трогать автоматически ------
Write-Host ''
Write-Host 'claude_desktop_config.json:' -ForegroundColor Yellow

$srcMcp = Join-Path $EvacDir 'roaming\claude_desktop_config.json'
$dstMcp = Join-Path $dstRoaming 'claude_desktop_config.json'

function Get-Names {
    param($Object)
    if ($null -eq $Object) { return @() }
    return @($Object.PSObject.Properties.Name)
}

if (Test-Path $srcMcp) {
    if (-not (Test-Path $dstMcp)) {
        if (-not $DryRun) { Copy-Item $srcMcp $dstMcp -Force }
        Write-Host '  здесь конфига не было — скопирован целиком' -ForegroundColor Green
    } else {
        $a = Get-Content $srcMcp -Raw -Encoding UTF8 | ConvertFrom-Json
        $b = Get-Content $dstMcp -Raw -Encoding UTF8 | ConvertFrom-Json
        $needsAttention = $false

        # -- MCP-серверы -------------------------------------------------
        $an = Get-Names $a.mcpServers
        $bn = Get-Names $b.mcpServers
        $onlyMcp = @($an | Where-Object { $bn -notcontains $_ })

        if ($an.Count -eq 0 -and $bn.Count -eq 0) {
            Write-Host '  MCP-серверы: не настроены ни там, ни здесь' -ForegroundColor DarkGray
        } else {
            $hereMcp  = '(нет)'; if ($bn.Count -gt 0) { $hereMcp  = $bn -join ', ' }
            $thereMcp = '(нет)'; if ($an.Count -gt 0) { $thereMcp = $an -join ', ' }
            Write-Host "  MCP-серверы здесь : $hereMcp"
            Write-Host "  MCP-серверы там   : $thereMcp"
            if ($onlyMcp.Count -gt 0) {
                $needsAttention = $true
                Write-Host ("  ! только на старой машине: {0}" -f ($onlyMcp -join ', ')) -ForegroundColor Magenta
                Write-Host '    Не сливаю автоматически: MCP-серверы ссылаются на локальные пути и команды,' -ForegroundColor DarkYellow
                Write-Host '    которых на этой машине может не быть. Перенеси нужные вручную.' -ForegroundColor DarkYellow
            }
        }

        # -- Доверенные папки Cowork -------------------------------------
        $at = @(); if ($a.preferences.localAgentModeTrustedFolders) { $at = @($a.preferences.localAgentModeTrustedFolders) }
        $bt = @(); if ($b.preferences.localAgentModeTrustedFolders) { $bt = @($b.preferences.localAgentModeTrustedFolders) }
        $onlyTrust = @($at | Where-Object { $bt -notcontains $_ })

        Write-Host ("  Доверенные папки: здесь {0}, там {1}" -f $bt.Count, $at.Count)
        if ($onlyTrust.Count -gt 0) {
            Write-Host '  ! доверены только на старой машине:' -ForegroundColor Magenta
            foreach ($t in $onlyTrust) { Write-Host "      $t" -ForegroundColor Magenta }
            Write-Host '    Не добавляю автоматически — это выдача прав на выполнение кода в папке.' -ForegroundColor DarkYellow
            Write-Host '    Claude сам спросит подтверждение при первом открытии каждой. Ничего не теряется.' -ForegroundColor DarkGray
        }

        # -- Прочие ключи, которых здесь нет -----------------------------
        $aKeys = Get-Names $a
        $bKeys = Get-Names $b
        $onlyKeys = @($aKeys | Where-Object { $bKeys -notcontains $_ })
        if ($onlyKeys.Count -gt 0) {
            $needsAttention = $true
            Write-Host ("  ! ключи, которых здесь нет: {0}" -f ($onlyKeys -join ', ')) -ForegroundColor Magenta
        }

        if ($needsAttention) {
            Write-Host "    Исходный файл для ручного переноса: $srcMcp" -ForegroundColor DarkYellow
        }
    }
} else {
    Write-Host '  нет данных' -ForegroundColor DarkGray
}

# --- 7. Проектные скиллы/агенты/команды в рабочие папки ------------------
Write-Host ''
Write-Host 'Скиллы и настройки внутри проектов:' -ForegroundColor Yellow

$srcCfgRoot = Join-Path $EvacDir 'project-configs'
$pending    = @()   # проекты, чьи папки ещё не перенесены

if (Test-Path $srcCfgRoot) {
    # folder -> реальный путь проекта, берём из карты сборщика
    $pathByFolder = @{}
    $mapCsv = Join-Path $EvacDir 'projects-map.csv'
    if (Test-Path $mapCsv) {
        foreach ($row in (Import-Csv $mapCsv -Delimiter ';' -Encoding UTF8)) {
            $pathByFolder[$row.'Папка'] = $row.'ПутьПроекта'
        }
    }

    foreach ($proj in Get-ChildItem $srcCfgRoot -Directory) {
        $target = $pathByFolder[$proj.Name]
        if (-not $target) {
            Write-Host ("  ?   {0} — путь неизвестен, пропускаю" -f $proj.Name) -ForegroundColor DarkYellow
            continue
        }

        if (-not (Test-Path $target)) {
            $pending += $target
            continue
        }

        $copied = 0; $exists = 0
        foreach ($f in Get-ChildItem $proj.FullName -Recurse -File) {
            $rel = $f.FullName.Substring($proj.FullName.Length).TrimStart('\')
            $to  = Join-Path $target $rel

            if (Test-Path $to) { $exists++; continue }   # своё не трогаем

            if (-not $DryRun) {
                $parent = Split-Path $to -Parent
                if (-not (Test-Path $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
                Copy-Item $f.FullName $to -Force
            }
            $copied++
        }

        if ($copied -gt 0) {
            Write-Host ("  OK  {0,-42} +{1} файл(ов)" -f $target, $copied) -ForegroundColor Green
        } else {
            Write-Host ("  ·   {0,-42} всё уже на месте ({1})" -f $target, $exists) -ForegroundColor DarkGray
        }
    }

    if ($pending.Count -gt 0) {
        Write-Host ''
        Write-Host '  Папки этих проектов ещё не перенесены — их скиллы не разложены:' -ForegroundColor Magenta
        foreach ($p in $pending) { Write-Host "      $p" -ForegroundColor Magenta }
        Write-Host '  Перенеси папки и запусти слияние повторно — оно безопасно для повтора.' -ForegroundColor DarkYellow
    }
} else {
    Write-Host '  нет данных (сборщик не нашёл проектных настроек)' -ForegroundColor DarkGray
}

# --- Итог ----------------------------------------------------------------
Write-Host ''
if ($DryRun) {
    Write-Host 'Пробный прогон завершён. Запусти без -DryRun, чтобы применить.' -ForegroundColor Cyan
} else {
    Write-Host 'Слияние завершено.' -ForegroundColor Green
    Write-Host "Откат: содержимое $backupDir" -ForegroundColor DarkGray
    Write-Host ''
    Write-Host 'Дальше:' -ForegroundColor Cyan
    if ($pending.Count -gt 0) {
        Write-Host '  1. Перенеси рабочие папки проектов, перечисленные выше,'
        Write-Host '     и запусти слияние ещё раз — оно разложит их проектные скиллы'
        Write-Host '  2. Запусти Claude, войди в аккаунт'
        Write-Host '  3. Проверь историю: claude --resume в любой из перенесённых папок'
    } else {
        Write-Host '  1. Запусти Claude, войди в аккаунт'
        Write-Host '  2. Проверь историю: claude --resume в любой из перенесённых папок'
    }
}
