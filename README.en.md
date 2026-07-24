# claude-data-migration

Move **Claude Code** and **Claude Desktop** data from one computer to another — conversation history, skills and settings included.

*[Русская версия](README.md)*

> **Note on language:** the scripts print their output in Russian. The code and this document are in English, but if you run the tools you will see Russian console messages. Contributions adding localisation are welcome.

This came out of a real migration: a work laptop was about to be wiped, holding dozens of Claude Code sessions, personal skills and per-project settings. That data lives in several different places — some of it *inside* project working folders — and losing a piece of it by hand is easy.

The key property: on the receiving machine the tool **merges rather than replaces**. Existing projects and history there are left untouched.

---

## What gets moved

| What | From | Notes |
|---|---|---|
| Claude Code conversation history | `~/.claude/projects/` | the main payload; JSONL transcripts |
| Personal skills, agents, commands | `~/.claude/{skills,agents,commands,hooks,todos}` | |
| Plugins and marketplaces | `~/.claude/plugins/` | |
| Global config | `~/.claude.json` | only `projects` entries are merged |
| Desktop settings and sessions | `%APPDATA%/Claude/` | MCP config, Cowork sessions |
| **Project-level** skills and settings | `<project>/.claude/`, `CLAUDE.md`, `.mcp.json` | these live inside working folders |
| Project working folders | paths from `~/.claude.json` | optional, behind a flag |

### Deliberately NOT moved

- **`~/.claude/.credentials.json`** — the auth token. Just sign in again on the new machine.
- **Caches** — `Cache`, `GPUCache`, `blob_storage`, `Network`, `vm_bundles` and friends. Easily several gigabytes of junk.
- **`AppData/Local/AnthropicClaude`** — that is the application itself, not your data. Reinstall it.
- **claude.ai chats** — those are stored server-side and sync back once you sign in.

---

## Requirements

- Windows
- **Python 3.8+** — the main path. Standard library only, nothing to install.
- PowerShell 5.1 — fallback collector, for a source machine without Python.

---

## Usage

### On the old machine (source)

Copy `collect_claude.py`, `COLLECT.bat` and `COLLECT-FULL.bat` there, then double-click:

- **`COLLECT.bat`** — Claude history and settings only
- **`COLLECT-FULL.bat`** — the same plus the project working folders (use this if the machine is being wiped)

Both show the size first and ask for confirmation. The result is `claude-evac.zip`.

Command line flags:

```bash
python collect_claude.py --dry-run                 # measure only
python collect_claude.py --zip                     # collect and archive
python collect_claude.py --zip --include-workdirs  # plus working folders
python collect_claude.py --profile "E:/Users/Name" # from a mounted disk
```

That last form helps when the old machine no longer boots: attach its drive and read the profile directly.

### On the new machine (target)

1. Unpack `claude-evac.zip` next to the scripts so you get a `claude-evac` folder
2. **`RESTORE-PROJECTS.bat`** — puts project working folders back at their original paths
3. **Close Claude completely**, including the tray icon
4. **`MERGE.bat`** — merges history, skills and settings into your profile

Both `.bat` files do a dry run first, show the plan and wait for confirmation.

---

## Things worth knowing

### The project path is encoded in the history folder name

Claude Code stores transcripts in folders named after the project path, with every non-alphanumeric character replaced by a hyphen:

```
C:\Projects\my-app      ->  C--Projects-my-app
D:\work\demo_service    ->  D--work-demo-service
```

The transform is lossy (`_`, space and `\` all collapse to `-`), so real paths are read from the `projects` keys in `~/.claude.json` and saved to `projects-map.csv`.

**Consequence:** projects must end up at the same paths on the new machine, or history will not attach to them. `RESTORE-PROJECTS.bat` handles this.

### Claude must be closed before merging

The app keeps `~/.claude.json` in memory and rewrites it on exit, silently discarding whatever was merged. `MERGE.bat` checks for a running process and refuses to proceed.

### Skills live in three places

1. Personal — `~/.claude/skills/`
2. Plugin-provided — `~/.claude/plugins/marketplaces/…`
3. **Project-level** — `<project folder>/.claude/skills/`

The third kind is the easy one to lose: it sits inside the working folder, not in your profile. The collector always picks it up, separately from the working folders themselves.

---

## Safety and reversibility

- `MERGE.bat` backs up the current state to `backup-before-merge_<date>` before touching anything
- Existing files are **never overwritten** — only missing ones are added
- `~/.claude.json` is edited surgically: `projects` entries are added, identifiers and tokens are left alone; the file is re-parsed after writing and changes roll back on failure
- Every script is idempotent — running it twice is safe
- MCP servers and trusted folders are **not merged automatically** — the former reference local paths, the latter grant code execution rights. The script reports differences and leaves the decision to you

---

## Contents

| File | Runs on | Purpose |
|---|---|---|
| `collect_claude.py` | source | collection |
| `COLLECT.bat` | source | collection launcher |
| `COLLECT-FULL.bat` | source | collection including working folders |
| `1-collect.ps1` | source | fallback collector, no Python needed |
| `restore_projects.py` | target | restores working folders |
| `RESTORE-PROJECTS.bat` | target | restore launcher |
| `2-merge.ps1` | target | merges into the profile |
| `MERGE.bat` | target | merge launcher |

Both collectors produce the same output layout, so a Python collection feeding a PowerShell merge works fine in any combination.

---

## License

MIT — see [LICENSE](LICENSE).
