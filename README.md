# BinMan

Personal CLI script/app manager for your `~/.local/bin` toys.  
Install, uninstall, list, update, and scaffold **single-file scripts** *and* **multi-file apps**.  
Includes a simple TUI menu and a tiny generator.

---

## Features

- **Install**: drop a script into `~/.local/bin/<name>` or an app into `~/.local/share/binman/apps/<name>` with a shim in `~/.local/bin/<name>`.
- **Uninstall**: remove a single command or a whole app (shim + store dir).
- **List**: show installed commands & apps with versions.
- **Update**: force-reinstall from a given file/dir path (good for quick edits).
- **Generator**: `binman new` scaffolds a ready-to-run script or app (bash/python).
- **TUI**: `binman` with no args opens a tiny menu.

> Version in this README: **v1.2.1** (matches your script).

---

## Quick install (of BinMan itself)

```bash
git clone <your repo url> ~/Projects/BinMan
cd ~/Projects/BinMan
chmod +x binman.sh
./binman.sh install binman.sh
# refresh your shell hash table (zsh: rehash; bash: hash -r)
rehash 2>/dev/null || hash -r 2>/dev/null || true
binman
```

If binman isn’t found, ensure ~/.local/bin is in your PATH:
```echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.zshrc
source ~/.zshrc
```

##How it works (mental model)

Scripts: You install a single executable file. BinMan copies it to ~/.local/bin/<filename-without-ext> and makes it executable.
```
Apps: A folder with an entrypoint: bin/<name>. BinMan copies the folder to
~/.local/share/binman/apps/<name> and creates a shim at ~/.local/bin/<name>:
```

##Version detection:

For scripts: first VERSION= / # Version: / __version__ = line.

For apps: VERSION file in the app dir, else the same search in bin/<name>.

---

## Usage

Run binman with no args to open the TUI
or use the commands below.

```# Script → command "hello"
./binman.sh install ./hello.sh

# Python script → command "resize"
./binman.sh install tools/resize.py

# App dir (must contain bin/<name>)
./binman.sh install ./MyApp
```

## Result

Scripts land in: ~/.local/bin/<name>

Apps land in: ~/.local/share/binman/apps/<name> + shim in ~/.local/bin/<name>

Tip: after install/uninstall, your shell may need rehash (zsh) or hash -r (bash).

---

