# BinMan

Personal CLI script/app manager for your `~/.local/bin` toys.  
Install, uninstall, list, update, and scaffold **single-file scripts** *and* **multi-file apps**.  
Includes a simple TUI menu and a tiny generator.

---

## Features

- **Install**: drop a script into `~/.local/bin/<name>` or an app into `~/.local/share/binman/apps/<name>`.
- **Uninstall**: remove a single command or a whole app (shim + store dir).
- **List**: show installed commands & apps with versions.
- **Update**: force-reinstall from a given file/dir path (good for quick edits).
- **Generator**: `binman new` scaffolds a ready-to-run script or app (bash/python).
- **TUI**: `binman` with no args opens a tiny menu.

Version in this README: **v1.2.1**

---

## Quick install (of BinMan itself)

```
git clone https://github.com/karialo/binman ~/Projects/BinMan
cd ~/Projects/BinMan
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

- **Scripts**: Installed as `~/.local/bin/<name>`. Extension dropped.
- **Apps**: Copied into `~/.local/share/binman/apps/<name>` with a shim in `~/.local/bin/<name>`.
- **Versions**: Detected from `VERSION=` / `# Version:` / `__version__` or a `VERSION` file.

Shim looks like:

```#!/usr/bin/env bash
exec "$HOME/.local/share/binman/apps/<name>/bin/<name>" "$@"
```

---

## Usage

### Install

```
binman install ./hello.sh
binman install ./tools/resize.py
binman install ./MyApp
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

### Update

```
binman update ./hello.sh
binman update ./MyApp
```

### Doctor

```
binman doctor
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

### TUI

```
binman tui
```

---

## Dev workflow tips

- **Edit + Update**

```
binman update path/to/script-or-app
rehash 2>/dev/null || hash -r 2>/dev/null || true
```

- **Entrypoint rule for apps**: executable must be `bin/<appname>`.

---

## Troubleshooting

- **TRY THIS FIRST**

- **If installed** → binman -h
- **If NOT installed** → ./binman.sh -h

- **command not found** → check PATH includes `~/.local/bin` + rehash.
- **permission denied** → `chmod +x` before install.
- **app won’t install** → must contain `bin/<name>`.

---

## Roadmap

- Smarter update metadata.
- Bulk git-aware updates.
- Optional Python venv support.

---

## License

MIT – do crimes (responsibly).
