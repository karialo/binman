# BinMan

Personal CLI script/app manager for your `~/.local/bin` toys.  
Install, uninstall, list, update, and scaffold **single-file scripts** *and* **multi-file apps**.  
Now with **backup/restore**, a tidy **doctor**, and both **wizard** + **TUI**.

---

## Features

- **Install**: drop a script into `~/.local/bin/<name>` or an app into `~/.local/share/binman/apps/<name>`.
- **Uninstall**: remove a single command or a whole app (shim + store dir).
- **List**: show installed commands & apps with versions.
- **Update**: force-reinstall from a given file/dir path (great for quick edits).
- **Generator**: `binman new` scaffolds a ready-to-run script or app (bash/python).
- **Wizard**: interactive project generator with README + optional git init.
- **TUI**: run `binman` with no args for a simple menu.
- **Backup/Restore**: snapshot `BIN_DIR` and `APP_STORE` to `.zip` (or `.tar.gz` fallback) and restore later.

Version in this README: **v1.4.0**

---

## Quick install (of BinMan itself)

```
git clone https://github.com/karialo/binman
cd BinMan
chmod +x binman.sh
./binman.sh install binman.sh
rehash 2>/dev/null || hash -r 2>/dev/null || true
binman
```

If `binman` isn’t found, ensure `~/.local/bin` is in your `PATH`:

```
echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.zshrc
source ~/.zshrc
```

---

## How it works

- **Scripts**: Installed as `~/.local/bin/<name>`. (Extension dropped.)
- **Apps**: Copied/symlinked into `~/.local/share/binman/apps/<name>` with a shim at `~/.local/bin/<name>`.
- **Versions**: Detected from `VERSION=` / `# Version:` / `__version__` or a `VERSION` file.

Shim looks like:

```
#!/usr/bin/env bash
exec "$HOME/.local/share/binman/apps/<name>/bin/<name>" "$@"
```

---

## Usage

### Global Options (apply to most commands)

- `--from DIR` — operate on all executables in DIR  
- `--link` — use symlinks instead of copying  
- `--force` — overwrite during install/restore  
- `--git DIR` — before `update`, run `git pull` in DIR  
- `--bin DIR` — override bin directory (default `~/.local/bin`)  
- `--apps DIR` — override apps directory (default `~/.local/share/binman/apps`)  
- `--fix-path` — with `doctor`, patch PATH into `~/.zshrc`/`~/.zprofile`

### Install

```
binman install ./hello.sh
binman install ./tools/resize.py
binman install ./MyApp            # expects ./MyApp/bin/MyApp
```

### Uninstall

```
binman uninstall hello
binman uninstall MyApp
```

### List

```
binman list
```

### Update (reinstall with overwrite)

```
binman update ./hello.sh
binman update ./MyApp
# Optional: auto-pull first
binman update --git ~/Projects/MyApp ./MyApp
```

### Doctor

```
binman doctor           # shows BIN_DIR/APP_STORE, PATH, zip/tar availability
binman doctor --fix-path
```

### New (scaffold)

```
binman new tidy.sh
binman new resize.py
binman new MediaTool --app --lang bash
binman new SmartTool --app --lang python --dir ~/Projects/Tools
```

Bash script scaffold:

```
#!/usr/bin/env bash
VERSION="0.1.0"
set -Eeuo pipefail
echo "Hello from <name> v$VERSION"
```

Python script scaffold:

```
#!/usr/bin/env python3
__version__ = "0.1.0"

def main():
    print(f"Hello from <name> v{__version__}")
    return 0

if __name__ == "__main__":
    import sys
    sys.exit(main())
```

App scaffold layout:

```
<name>/
├─ bin/<name>
├─ src/
└─ VERSION
```

### Wizard (interactive)

```
binman wizard
```

Prompts for name, type (single/app), language (bash/python), directory, author/desc, installs optionally, and can init git via `gitprep` if available.

### TUI

```
binman tui
# or just: binman
```

Menu includes Install, Uninstall, List, Doctor, New, Wizard, **Backup**, **Restore**.

---

## Backup & Restore

Create safe snapshots of everything BinMan manages.

### Backup

- If `zip/unzip` exist → `.zip`  
- Otherwise falls back to `.tar.gz`

```
# Timestamped file in CWD
binman backup

# Custom filename (extension auto-added if missing)
binman --backup my-stash.zip
binman backup my-stash.tgz
```

Backup contents:
- `bin/` — your commands from `BIN_DIR`
- `apps/` — your app directories from `APP_STORE`
- `meta/info.txt` — metadata (timestamp, host, paths, BinMan version)

### Restore

Merges archive back into your current `BIN_DIR` and `APP_STORE`.  
Skips existing files unless `--force` is provided.

```
# Standard restore (no overwrite)
binman restore binman_backup-20250101-120000.zip

# Force overwrite existing files
binman --restore binman_backup-20250101-120000.zip --force

# Alternate archive types supported
binman restore my-stash.tgz
```

---

## Dev workflow tips

- **Edit + Update**

```
binman update path/to/script-or-app
rehash 2>/dev/null || hash -r 2>/dev/null || true
```

- **Entrypoint rule for apps**: executable must be `bin/<appname>`.
- **Symlink installs** for live-edit dev: pass `--link` during install.

---

## Troubleshooting

- **Try these first:**
  - Installed? → `binman -h`
  - Not installed? → `./binman.sh -h`

Common issues:
- **`command not found`** → ensure `~/.local/bin` on `PATH` + rehash.
- **`permission denied`** → `chmod +x` before `install`.
- **App won’t install** → must contain `bin/<name>`.
- **Restore didn’t overwrite** → use `--force`.
- **No `zip/unzip`** → `doctor` will warn; backup falls back to `.tar.gz`.

---

## Roadmap

- Smarter update metadata.
- Bulk git-aware updates.
- Optional Python venv support for app scaffolds.
- (Maybe) `--system` target for `/usr/local` with sudo guards.

---

## License

MIT – do crimes (responsibly).
