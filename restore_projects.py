#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Раскладывание рабочих папок проектов из архива по их настоящим путям.

Запускать НА НОВОЙ МАШИНЕ, после распаковки claude-evac.zip
и ДО запуска MERGE.bat.

Сборщик кладёт папки под служебными именами:
    workdirs/C--Projects-web-api/  ->  C:\\Projects\\web\\api

Соответствие берётся из projects-map.csv, который лежит рядом.
Существующие файлы не перезаписываются.

Примеры:
    python restore_projects.py --dry-run
    python restore_projects.py
    python restore_projects.py --evac "E:/transfer/claude-evac"
"""

from __future__ import annotations

import argparse
import csv
import os
import shutil
import sys
from pathlib import Path

BANNER = "=" * 74


def setup_console() -> None:
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
    s = str(p)
    if os.name == "nt" and len(s) > 240 and not s.startswith("\\\\?\\"):
        return "\\\\?\\" + os.path.abspath(s)
    return s


def read_map(evac: Path) -> list[dict]:
    """Карта соответствий: служебное имя папки -> настоящий путь проекта."""
    csv_path = evac / "projects-map.csv"
    if not csv_path.exists():
        print(f"  ОШИБКА: не найден {csv_path}")
        print("  Без него неизвестно, куда раскладывать папки.")
        sys.exit(1)

    rows: list[dict] = []
    # сборщик пишет UTF-8 с BOM и разделителем ';'
    with open(csv_path, "r", encoding="utf-8-sig", newline="") as fh:
        for row in csv.DictReader(fh, delimiter=";"):
            rows.append({
                "folder": row.get("Папка", "").strip(),
                "path": row.get("ПутьПроекта", "").strip(),
                "existed": row.get("ЕстьНаДиске", "").strip().lower() == "да",
            })
    return rows


def restore(evac: Path, dry_run: bool, overwrite: bool) -> int:
    rows = read_map(evac)
    workdirs = evac / "workdirs"

    print(BANNER)
    print("  РАСКЛАДЫВАНИЕ РАБОЧИХ ПАПОК ПРОЕКТОВ")
    print(BANNER)
    print(f"  Архив  : {evac}")
    if dry_run:
        print("  Режим  : ПРОБНЫЙ ПРОГОН — ничего не записывается")
    print(BANNER)
    print()

    if not workdirs.is_dir():
        print("  В архиве нет папки workdirs.")
        print("  Значит сбор делали без --include-workdirs (кнопкой COLLECT.bat).")
        print("  Рабочие папки нужно перенести самостоятельно, по путям из projects-map.csv:")
        print()
        for r in rows:
            if r["existed"]:
                print(f"    {r['path']}")
        return 1

    total_copied = total_skipped = total_bytes = 0
    made_empty: list[str] = []
    problems: list[str] = []

    for row in rows:
        if not row["existed"] or not row["path"]:
            continue

        target = Path(row["path"])
        source = workdirs / row["folder"]

        # Проект был пустой папкой: в zip пустые каталоги не попадают,
        # поэтому просто создаём её, чтобы путь существовал.
        if not source.is_dir():
            if not target.exists():
                if not dry_run:
                    try:
                        target.mkdir(parents=True, exist_ok=True)
                    except OSError as exc:
                        problems.append(f"{target}: {exc}")
                        continue
                made_empty.append(str(target))
            continue

        copied = skipped = size = 0
        for root, _dirs, files in os.walk(long_path(source)):
            rel = os.path.relpath(root, long_path(source))
            dst_dir = target if rel == "." else target / rel

            for name in files:
                src_file = Path(root) / name
                dst_file = dst_dir / name

                if dst_file.exists() and not overwrite:
                    skipped += 1
                    continue

                if not dry_run:
                    try:
                        dst_dir.mkdir(parents=True, exist_ok=True)
                        shutil.copy2(long_path(src_file), long_path(dst_file))
                    except OSError as exc:
                        problems.append(f"{src_file}: {exc}")
                        continue

                copied += 1
                try:
                    size += src_file.stat().st_size
                except OSError:
                    pass

        total_copied += copied
        total_skipped += skipped
        total_bytes += size

        if copied:
            note = f"  (пропущено уже существующих: {skipped})" if skipped else ""
            print(f"  OK   {row['path']:<40} +{copied:>4} файл(ов)  {human(size):>10}{note}")
        else:
            print(f"  ·    {row['path']:<40} всё уже на месте ({skipped})")

    if made_empty:
        print()
        print("  Созданы пустые папки (в этих проектах не было файлов):")
        for p in made_empty:
            print(f"      {p}")

    if problems:
        print()
        print(f"  НЕ УДАЛОСЬ ({len(problems)}):")
        for p in problems[:20]:
            print(f"      {p}")

    print()
    print(BANNER)
    print(f"  Скопировано: {total_copied} файл(ов), {human(total_bytes)}")
    if total_skipped:
        print(f"  Пропущено (уже были на месте): {total_skipped}")

    if dry_run:
        print("\n  Запусти без --dry-run, чтобы выполнить.")
    else:
        print("\n  Дальше: полностью закрой Claude и запусти MERGE.bat —")
        print("  он вольёт историю диалогов и разложит проектные скиллы.")
    print(BANNER)
    return 0


def main() -> int:
    setup_console()

    parser = argparse.ArgumentParser(
        description="Раскладывает рабочие папки проектов из архива по их настоящим путям.",
    )
    parser.add_argument("--evac", type=Path, default=None,
                        help="папка claude-evac (по умолчанию рядом со скриптом)")
    parser.add_argument("--dry-run", action="store_true",
                        help="только показать план, ничего не записывать")
    parser.add_argument("--overwrite", action="store_true",
                        help="перезаписывать существующие файлы (по умолчанию они не трогаются)")
    args = parser.parse_args()

    evac = args.evac or (Path(__file__).resolve().parent / "claude-evac")
    evac = evac.resolve()

    if not evac.is_dir():
        print(f"ОШИБКА: не найдена папка {evac}")
        print("Распакуй сюда claude-evac.zip со старой машины.")
        return 1

    return restore(evac, args.dry_run, args.overwrite)


if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        print("\nПрервано пользователем.")
        sys.exit(130)
