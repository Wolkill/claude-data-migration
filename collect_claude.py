#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Сбор данных Claude со СТАРОГО компьютера для переноса на новый.

Запускать НА ТОЙ МАШИНЕ, С КОТОРОЙ ЭВАКУИРУЕМСЯ.
Только стандартная библиотека — ничего доустанавливать не нужно.

Что забирает:
    ~/.claude/projects/         транскрипты всех диалогов Claude Code (главное)
    ~/.claude/*                 настройки, плагины, бэкапы, агенты, команды, навыки
    ~/.claude.json              глобальный конфиг: MCP-серверы, список проектов
    %APPDATA%/Claude/           MCP-конфиг десктопа + локальные сессии Cowork

Что НЕ забирает намеренно:
    .credentials.json           токен авторизации — на новой машине войти заново
    Cache, GPUCache, blob_storage, Network, vm_bundles и пр.  — мусор (~10 ГБ)
    AppData/Local/AnthropicClaude — это сама программа, не данные

Примеры:
    python collect_claude.py
    python collect_claude.py --zip
    python collect_claude.py --dry-run
    python collect_claude.py --profile "E:/Users/Ivan" --out "E:/claude-evac"
    python collect_claude.py --zip --include-workdirs
"""

from __future__ import annotations

import argparse
import csv
import json
import os
import re
import shutil
import socket
import sys
import zipfile
from datetime import datetime
from pathlib import Path

# ---------------------------------------------------------------------------
# Что собираем
# ---------------------------------------------------------------------------

# ~/.claude/<имя> — одиночные файлы
CLAUDE_FILES = [
    "history.jsonl",       # история промптов
    "settings.json",
    "CLAUDE.md",           # глобальные инструкции
    "MEMORY.md",
    "keybindings.json",
]

# ~/.claude/<имя> — каталоги целиком
CLAUDE_DIRS = [
    "projects",            # ГЛАВНОЕ: транскрипты диалогов + memory проектов
    "plugins",
    "backups",
    "todos",
    "agents",
    "commands",
    "skills",
    "hooks",
    "memory",
]

# <profile>/AppData/Roaming/Claude/<имя>
ROAMING_FILES = [
    "claude_desktop_config.json",   # MCP-серверы десктопа
    "config.json",
    "git-worktrees.json",
]
ROAMING_DIRS = [
    "local-agent-mode-sessions",    # локальные сессии Cowork
    "claude-code-sessions",
]

# Никогда не копируем
NEVER_COPY = {".credentials.json", "credentials.json"}

# Конфигурация Claude ВНУТРИ рабочей папки проекта.
# Здесь живут проектные скиллы, агенты, команды и MCP-серверы — то, что
# иначе уехало бы только вместе со всей папкой проекта.
PROJECT_CONFIG_DIRS = [".claude"]          # skills, agents, commands, settings*.json
PROJECT_CONFIG_FILES = [
    "CLAUDE.md",
    "CLAUDE.local.md",
    ".mcp.json",                            # проектные MCP-серверы
]

# При --include-workdirs эти каталоги внутри рабочих папок пропускаем
WORKDIR_SKIP = {
    "node_modules", ".venv", "venv", "env", "__pycache__", ".mypy_cache",
    ".pytest_cache", ".ruff_cache", "dist", "build", ".next", ".turbo",
    "target", "bin", "obj", ".gradle", ".idea", ".tox",
}

BANNER = "=" * 74


# ---------------------------------------------------------------------------
# Утилиты
# ---------------------------------------------------------------------------

def setup_console() -> None:
    """Чтобы кириллица не ломалась в cmd.exe."""
    for stream in (sys.stdout, sys.stderr):
        try:
            stream.reconfigure(encoding="utf-8", errors="replace")
        except (AttributeError, ValueError):
            pass


def human(num_bytes: int) -> str:
    size = float(num_bytes)
    for unit in ("Б", "КБ", "МБ", "ГБ"):
        if size < 1024 or unit == "ГБ":
            return f"{size:,.1f} {unit}".replace(",", " ")
        size /= 1024
    return f"{size:.1f} ГБ"


def long_path(p: Path) -> str:
    """Обход лимита в 260 символов на Windows."""
    s = str(p)
    if os.name == "nt" and len(s) > 240 and not s.startswith("\\\\?\\"):
        return "\\\\?\\" + os.path.abspath(s)
    return s


def measure(path: Path, skip_dirs: set[str] | None = None) -> tuple[int, int]:
    """(количество файлов, суммарный размер). Ошибки доступа игнорируются."""
    files = total = 0
    if not path.exists():
        return 0, 0
    if path.is_file():
        try:
            return 1, path.stat().st_size
        except OSError:
            return 0, 0

    stack = [path]
    while stack:
        current = stack.pop()
        try:
            with os.scandir(long_path(current)) as entries:
                for entry in entries:
                    try:
                        if entry.is_dir(follow_symlinks=False):
                            if skip_dirs and entry.name in skip_dirs:
                                continue
                            stack.append(Path(entry.path))
                        elif entry.is_file(follow_symlinks=False):
                            files += 1
                            total += entry.stat(follow_symlinks=False).st_size
                    except OSError:
                        continue
        except (OSError, PermissionError):
            continue
    return files, total


def copy_tree(src: Path, dst: Path, skip_dirs: set[str] | None = None) -> tuple[int, int, list[str]]:
    """Рекурсивное копирование, устойчивое к ошибкам доступа."""
    copied = total = 0
    problems: list[str] = []

    if src.is_file():
        try:
            dst.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(long_path(src), long_path(dst))
            return 1, src.stat().st_size, problems
        except OSError as exc:
            return 0, 0, [f"{src}: {exc}"]

    for root, dirnames, filenames in os.walk(long_path(src), onerror=lambda e: problems.append(str(e))):
        if skip_dirs:
            dirnames[:] = [d for d in dirnames if d not in skip_dirs]

        rel = os.path.relpath(root, long_path(src))
        target_dir = dst if rel == "." else dst / rel
        try:
            target_dir.mkdir(parents=True, exist_ok=True)
        except OSError as exc:
            problems.append(f"{target_dir}: {exc}")
            continue

        for name in filenames:
            if name in NEVER_COPY:
                continue
            source_file = Path(root) / name
            try:
                shutil.copy2(long_path(source_file), long_path(target_dir / name))
                copied += 1
                total += source_file.stat().st_size
            except OSError as exc:
                problems.append(f"{source_file}: {exc}")

    return copied, total, problems


def folder_name_for(project_path: str) -> str:
    """Правило Claude Code: всё, кроме букв и цифр -> '-'.

    C:\\Projects\\my-app      -> C--Projects-my-app
    D:\\work\\demo_service    -> D--work-demo-service   ('_' тоже становится '-')
    """
    return re.sub(r"[^A-Za-z0-9]", "-", project_path)


# ---------------------------------------------------------------------------
# Сбор
# ---------------------------------------------------------------------------

class Collector:
    def __init__(self, profile: Path, out: Path, dry_run: bool):
        self.profile = profile
        self.out = out
        self.dry_run = dry_run

        self.src_claude = profile / ".claude"
        self.src_json = profile / ".claude.json"
        self.src_roaming = profile / "AppData" / "Roaming" / "Claude"

        self.total_files = 0
        self.total_bytes = 0
        self.problems: list[str] = []
        self.collected: list[dict] = []

    def grab(self, src: Path, dst: Path, label: str, skip: set[str] | None = None) -> None:
        if not src.exists():
            print(f"  ·    {label:<34} нет")
            return

        if self.dry_run:
            files, size = measure(src, skip)
        else:
            files, size, problems = copy_tree(src, dst, skip)
            self.problems.extend(problems)

        self.total_files += files
        self.total_bytes += size
        self.collected.append({"label": label, "files": files, "bytes": size})
        print(f"  OK   {label:<34} {files:>6} файл(ов)  {human(size):>12}")

    def run(self) -> dict:
        print(BANNER)
        print("  СБОР ДАННЫХ CLAUDE ДЛЯ ПЕРЕНОСА")
        print(BANNER)
        print(f"  Компьютер : {socket.gethostname()}")
        print(f"  Профиль   : {self.profile}")
        print(f"  Приёмник  : {self.out}")
        if self.dry_run:
            print("  Режим     : ПРОБНЫЙ ПРОГОН — ничего не копируется")
        print(BANNER)

        if not self.src_claude.exists() and not self.src_json.exists():
            print()
            print("  ОШИБКА: в этом профиле нет данных Claude.")
            print(f"  Ожидались {self.src_claude} или {self.src_json}")
            print("  Укажи правильный профиль через --profile")
            sys.exit(1)

        if not self.dry_run:
            self.out.mkdir(parents=True, exist_ok=True)

        # --- Claude Code -------------------------------------------------
        print("\n[1/4] Claude Code  (~/.claude)")
        self.grab(self.src_claude / "projects", self.out / "claude" / "projects",
                  "projects (транскрипты)")
        for name in CLAUDE_FILES:
            self.grab(self.src_claude / name, self.out / "claude" / name, name)
        for name in CLAUDE_DIRS:
            if name == "projects":
                continue
            self.grab(self.src_claude / name, self.out / "claude" / name, name)

        # --- Глобальный конфиг -------------------------------------------
        print("\n[2/4] Глобальный конфиг")
        self.grab(self.src_json, self.out / "claude.json", ".claude.json")

        # --- Claude Desktop ----------------------------------------------
        print("\n[3/4] Claude Desktop  (AppData/Roaming/Claude)")
        for name in ROAMING_FILES + ROAMING_DIRS:
            self.grab(self.src_roaming / name, self.out / "roaming" / name, name)

        # --- Карта проектов ------------------------------------------------
        print("\n[4/5] Рабочие папки проектов")
        projects = self.build_project_map()

        # --- Проектные скиллы/агенты/команды -------------------------------
        print("\n[5/5] Настройки Claude внутри проектов")
        self.collect_project_configs(projects)

        account = self.read_account()
        return {"projects": projects, "account": account}

    def collect_project_configs(self, projects: list[dict]) -> None:
        """Забираем <проект>/.claude, CLAUDE.md и .mcp.json из каждой рабочей папки.

        Это проектные скиллы, агенты, команды и MCP-серверы. Весят мало,
        поэтому берём всегда — независимо от --include-workdirs.
        """
        found_any = False

        for row in projects:
            if not row["exists"]:
                continue

            src_root = Path(row["path"])
            dst_root = self.out / "project-configs" / row["folder"]
            picked: list[str] = []
            files = size = 0

            for name in PROJECT_CONFIG_DIRS + PROJECT_CONFIG_FILES:
                src = src_root / name
                if not src.exists():
                    continue

                if self.dry_run:
                    n, sz = measure(src)
                else:
                    n, sz, problems = copy_tree(src, dst_root / name)
                    self.problems.extend(problems)

                if n:
                    picked.append(name)
                    files += n
                    size += sz

            if not picked:
                continue

            found_any = True
            self.total_files += files
            self.total_bytes += size
            row["has_project_config"] = True

            # что именно нашли — скиллы показываем отдельно, они самые ценные
            detail = []
            for sub in ("skills", "agents", "commands"):
                sub_path = src_root / ".claude" / sub
                if sub_path.is_dir():
                    count = len([p for p in sub_path.iterdir() if not p.name.startswith(".")])
                    if count:
                        detail.append(f"{sub}: {count}")

            suffix = f"   [{', '.join(detail)}]" if detail else ""
            print(f"  OK   {row['path']:<40} {files:>4} файл(ов)  {human(size):>10}{suffix}")

        if not found_any:
            print("  ·    ни в одном проекте нет своих настроек Claude")

    # -- разбор .claude.json ------------------------------------------------

    def load_config(self) -> dict | None:
        if not self.src_json.exists():
            return None
        try:
            with open(self.src_json, "r", encoding="utf-8") as fh:
                return json.load(fh)
        except (OSError, json.JSONDecodeError) as exc:
            self.problems.append(f".claude.json не разобран: {exc}")
            return None

    def read_account(self) -> dict:
        cfg = self.load_config() or {}
        acc = cfg.get("oauthAccount") or {}
        return {
            "email": acc.get("emailAddress"),
            "organization": acc.get("organizationName"),
            "userID": cfg.get("userID"),
        }

    def build_project_map(self) -> list[dict]:
        """Настоящие пути берём из ключей projects в .claude.json.

        Имя папки — это путь с заменой не-буквенно-цифровых символов на '-',
        поэтому обратное преобразование неоднозначно и на глаз ненадёжно.
        """
        proj_root = self.src_claude / "projects"
        if not proj_root.is_dir():
            print("  ·    папки projects нет")
            return []

        cfg = self.load_config() or {}
        by_folder: dict[str, str] = {}
        for key in (cfg.get("projects") or {}):
            folder = folder_name_for(key)
            # предпочитаем вариант с обратными слэшами — канонический для Windows
            if folder not in by_folder or "\\" in key:
                by_folder[folder] = key

        rows: list[dict] = []
        for entry in sorted(proj_root.iterdir()):
            if not entry.is_dir():
                continue

            real = by_folder.get(entry.name)
            if real:
                path, source = real, "config"
            else:
                path = re.sub(r"-", "\\\\", re.sub(r"^([A-Za-z])--", r"\1:\\", entry.name))
                source = "ПРОВЕРЬ"

            sessions = len(list(entry.glob("*.jsonl")))
            exists = Path(path).is_dir()
            wd_files, wd_bytes = measure(Path(path), WORKDIR_SKIP) if exists else (0, 0)

            rows.append({
                "folder": entry.name,
                "path": path,
                "path_source": source,
                "sessions": sessions,
                "exists": exists,
                "workdir_files": wd_files,
                "workdir_bytes": wd_bytes,
                "has_project_config": False,   # заполняется в collect_project_configs
            })

        if not rows:
            print("  ·    проектов не найдено")
            return rows

        width = max(len(r["path"]) for r in rows)
        print(f"  {'ПУТЬ ПРОЕКТА':<{width}}  {'СЕССИЙ':>6}  {'ЕСТЬ':>5}  {'РАЗМЕР':>12}  ИСТОЧНИК")
        for r in rows:
            mark = "да" if r["exists"] else "НЕТ"
            size = human(r["workdir_bytes"]) if r["exists"] else "—"
            print(f"  {r['path']:<{width}}  {r['sessions']:>6}  {mark:>5}  {size:>12}  {r['path_source']}")

        if any(r["path_source"] == "ПРОВЕРЬ" for r in rows):
            print("\n  ! Для строк 'ПРОВЕРЬ' путь восстановлен приблизительно — сверь вручную.")
        if any(not r["exists"] for r in rows):
            print("  ! Папки с пометкой 'НЕТ' на этой машине отсутствуют (перемещены или удалены).")

        return rows


# ---------------------------------------------------------------------------
# Отчёты и упаковка
# ---------------------------------------------------------------------------

def write_reports(out: Path, collector: Collector, info: dict, args) -> None:
    projects = info["projects"]
    account = info["account"]

    with open(out / "projects-map.csv", "w", encoding="utf-8-sig", newline="") as fh:
        writer = csv.writer(fh, delimiter=";")
        writer.writerow(["Папка", "ПутьПроекта", "ИсточникПути", "Сессий",
                         "ЕстьНаДиске", "ФайловВПапке", "РазмерБайт"])
        for r in projects:
            writer.writerow([r["folder"], r["path"], r["path_source"], r["sessions"],
                             "да" if r["exists"] else "нет", r["workdir_files"], r["workdir_bytes"]])

    manifest = {
        "created": datetime.now().isoformat(timespec="seconds"),
        "source_host": socket.gethostname(),
        "source_profile": str(collector.profile),
        "account": account,
        "totals": {"files": collector.total_files, "bytes": collector.total_bytes},
        "collected": collector.collected,
        "projects": projects,
        "workdirs_included": bool(args.include_workdirs),
        "problems": collector.problems[:200],
    }
    with open(out / "MANIFEST.json", "w", encoding="utf-8") as fh:
        json.dump(manifest, fh, ensure_ascii=False, indent=2)

    lines = [
        "ПЕРЕНОС ДАННЫХ CLAUDE",
        "",
        f"Собрано      : {datetime.now():%Y-%m-%d %H:%M:%S}",
        f"Компьютер    : {socket.gethostname()}",
        f"Профиль      : {collector.profile}",
        f"Аккаунт      : {account.get('email') or 'не определён'}",
        f"Объём        : {collector.total_files} файл(ов), {human(collector.total_bytes)}",
        "",
        "ЧТО ДАЛЬШЕ, НА НОВОЙ МАШИНЕ:",
        "",
        "1. Распакуй эту папку рядом со скриптами, под именем  claude-evac",
        "",
        "2. Запусти двойным кликом  RESTORE-PROJECTS.bat",
        "   Он разложит рабочие папки проектов по их настоящим путям.",
        "   Путь зашит в имя папки с историей — при другом пути история не привяжется.",
        "",
        "3. ПОЛНОСТЬЮ закрой Claude — включая значок в трее.",
        "",
        "4. Запусти двойным кликом  MERGE.bat",
        "   Он сначала покажет пробный прогон, потом спросит подтверждение.",
        "",
        "5. Запусти Claude и войди в аккаунт (токен намеренно не переносится).",
        "",
        "ПУТИ ПРОЕКТОВ:",
    ]
    for r in projects:
        flag = "" if r["exists"] else "   [на диске отсутствует]"
        check = "" if r["path_source"] == "config" else "   [ПРОВЕРЬ ПУТЬ]"
        cfg = "   [есть свои скиллы/настройки]" if r.get("has_project_config") else ""
        lines.append(f"  {r['path']}   — сессий: {r['sessions']}{flag}{check}{cfg}")

    if any(r.get("has_project_config") for r in projects):
        lines += [
            "",
            "ПРОЕКТНЫЕ СКИЛЛЫ И НАСТРОЙКИ:",
            "  Лежат в папке project-configs (это <проект>/.claude, CLAUDE.md, .mcp.json).",
            "  MERGE.bat разложит их обратно по рабочим папкам — но только в те,",
            "  которые к моменту запуска уже перенесены на новую машину.",
            "  Существующие файлы не перезаписываются.",
        ]

    if collector.problems:
        lines += ["", f"НЕ УДАЛОСЬ СКОПИРОВАТЬ ({len(collector.problems)}):"]
        lines += [f"  {p}" for p in collector.problems[:40]]
        if len(collector.problems) > 40:
            lines.append(f"  ... и ещё {len(collector.problems) - 40}")

    (out / "ОТЧЁТ.txt").write_text("\n".join(lines) + "\n", encoding="utf-8")


def copy_workdirs(out: Path, projects: list[dict], collector: Collector) -> None:
    print("\n[+] Рабочие папки проектов (--include-workdirs)")
    target_root = out / "workdirs"
    for r in projects:
        if not r["exists"]:
            continue
        src = Path(r["path"])
        dst = target_root / r["folder"]
        copied, size, problems = copy_tree(src, dst, WORKDIR_SKIP)
        collector.problems.extend(problems)
        collector.total_files += copied
        collector.total_bytes += size
        print(f"  OK   {r['path']:<44} {copied:>6} файл(ов)  {human(size):>12}")
    print("  (пропущены node_modules, .venv, __pycache__, dist, build и подобные)")


def make_zip(out: Path) -> Path:
    archive = out.with_suffix(".zip")
    if archive.exists():
        archive.unlink()

    files = [p for p in out.rglob("*") if p.is_file()]
    print(f"\nУпаковка {len(files)} файл(ов) в архив...")

    with zipfile.ZipFile(archive, "w", zipfile.ZIP_DEFLATED, compresslevel=6) as zf:
        for i, path in enumerate(files, 1):
            try:
                zf.write(long_path(path), path.relative_to(out).as_posix())
            except OSError as exc:
                print(f"  пропущен {path}: {exc}")
            if i % 500 == 0:
                print(f"  ... {i}/{len(files)}")

    return archive


# ---------------------------------------------------------------------------

def main() -> int:
    setup_console()

    parser = argparse.ArgumentParser(
        description="Сбор данных Claude со старого компьютера для переноса на новый.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument("--profile", type=Path, default=None,
                        help="корень профиля-источника (по умолчанию — текущий пользователь); "
                             "для подключённого диска: E:/Users/Имя")
    parser.add_argument("--out", type=Path, default=None,
                        help="куда складывать (по умолчанию claude-evac рядом со скриптом)")
    parser.add_argument("--zip", action="store_true", help="упаковать результат в .zip")
    parser.add_argument("--dry-run", action="store_true", help="только показать объём, ничего не копировать")
    parser.add_argument("--include-workdirs", action="store_true",
                        help="забрать ещё и сами рабочие папки проектов (может быть много)")
    args = parser.parse_args()

    profile = (args.profile or Path(os.path.expanduser("~"))).resolve()
    default_out = Path(__file__).resolve().parent / "claude-evac"
    out = (args.out or default_out).resolve()

    if not profile.is_dir():
        print(f"ОШИБКА: профиль не найден — {profile}")
        return 1

    collector = Collector(profile, out, args.dry_run)
    info = collector.run()

    if args.dry_run:
        files = collector.total_files
        size = collector.total_bytes

        print(f"\n{BANNER}")
        print(f"  История и настройки Claude : {files} файл(ов), {human(size)}")

        if args.include_workdirs:
            wd_files = sum(r["workdir_files"] for r in info["projects"] if r["exists"])
            wd_bytes = sum(r["workdir_bytes"] for r in info["projects"] if r["exists"])
            files += wd_files
            size += wd_bytes
            print(f"  Рабочие папки проектов     : {wd_files} файл(ов), {human(wd_bytes)}")
            print(f"  {'-' * 70}")
            print(f"  ВСЕГО                      : {files} файл(ов), {human(size)}")
        else:
            print("  Рабочие папки проектов не включены (добавь --include-workdirs)")

        print("\n  Запусти без --dry-run, чтобы выполнить.")
        print(BANNER)
        return 0

    if args.include_workdirs:
        copy_workdirs(out, info["projects"], collector)

    write_reports(out, collector, info, args)

    print(f"\n{BANNER}")
    print(f"  Собрано: {collector.total_files} файл(ов), {human(collector.total_bytes)}")
    if collector.problems:
        print(f"  Не скопировано: {len(collector.problems)} — подробности в ОТЧЁТ.txt")

    if args.zip:
        archive = make_zip(out)
        print(f"  Архив: {archive}  ({human(archive.stat().st_size)})")
        print("\n  Перенеси этот .zip на новый компьютер.")
    else:
        print(f"\n  Папка: {out}")
        print("  Перенеси её на новый компьютер (или перезапусти с --zip).")

    print(f"\n  Инструкция что делать дальше — в файле  ОТЧЁТ.txt")
    print("  Токен авторизации не копировался: на новой машине просто войди в аккаунт.")
    print(BANNER)
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        print("\nПрервано пользователем.")
        sys.exit(130)
