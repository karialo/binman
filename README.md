## BinMan (Binary Manager)

Because your ~/Downloads folder is not a filing system, champ.

Let’s be honest: your scripts are everywhere. Some live in ~/Desktop, some in ~/Downloads, one’s rotting in ~/Documents/old_stuff/maybe_useful/ and the crown jewel—final2_REALfinal.sh—is hiding on a random USB stick you lost in 2019.

When you do find them, you rename one to “script.sh” because you’re a visionary, then overwrite it by accident two weeks later. Genius.

# BinMan fixes that.

Install your scripts or apps (even multi-file monsters) straight into ~/.local/bin or your system bin. Suddenly you can run them anywhere—no more “cd into directory, chmod +x, ./script.sh” like a caveman summoning fire.

Update them when you tweak your masterpiece. BinMan is version aware, so it swaps the old for the new like a well-trained butler.

Uninstall when you realize your brilliant script was actually a crime against humanity, or straight up tried to sudo rm -rf /* your box. 

Install from URL. Found some spicy script on GitHub? Just copy the raw link and:
```binman install --url https://raw.githubusercontent.com/someguy/wifi-slap/main/wifi-slap.sh```
Boom. It’s in your bin. Anywhere on your system. Ready to slap WiFi.

List what you’ve got installed, because you definitely forgot.

Backup & Restore. Zip your entire bin, yeet it onto a USB, upload it to cloud, carve it into a stone tablet. Restore later like a necromancer performing dark rites.

Doctor: checks if everything’s working or if you’ve somehow replaced bash with Minesweeper.


But wait—BinMan ships with friends. Example: gitprep.sh.

GitPrep is like repo-in-a-can. Run it in any directory and it’ll:

Initialize git

Add a README and .gitignore

Make the first commit

Hook up a remote if you want


One command, and your random folder full of horrors is a legit repo. No excuses now.

DIY mode: BinMan has a wizard to generate your own apps. You can spin up a project with metadata, versioning, README, optional Python venv, and git baked in. It’s like scaffolding, but less construction site and more “hello, here’s your new pet goblin.”

Examples of chaos you can install:

Coffeebuzz.sh – screams if your cup is empty.
```binman install coffeebuzz.sh```

Shrekify.py – renames every file to Shrek quotes.
```binman install --url https://raw.githubusercontent.com/you/shrekify/main/shrekify.py```

Wifi-slap.sh – pings your router into submission.
```binman install wifi-slap.sh```

Panicbutton.sh – hides your browser tabs and blasts Never Gonna Give You Up at full volume.
```binman install panicbutton.sh```

Minecraft-tunnel.lua – controls your turtle army like a cyber overlord.
```binman install minecraft-tunnel.lua```


And when you break something? BinMan lets you roll back. Yep, it actually tracks versions. That’s right—you can undo your mistakes like a time traveler with slightly better hair.

BinMan is not just a tool. It’s not just a package manager. It’s a lifestyle choice. It’s the line between order and chaos, between ~/Downloads and digital nirvana.

So… do you keep pretending your system is “organized enough,” or do you let BinMan drag your scripts out of the mud and into the bin.

DO IT! DO IT NOW!!

---

## Features

- **Install**: files, apps, or even remote URLs → into `~/.local/bin` or `~/.local/share/binman/apps`.
- **Uninstall**: remove a single command or a whole app (shim + store dir).
- **List**: show installed commands & apps with version and docstring (from top comment).
- **Update**: force-reinstall from file/dir, optionally with a `--git` pull first.
- **Backup/Restore**: snapshot + restore everything, `.zip` or `.tar.gz`.
- **Rollback**: auto-snapshots before changes; roll back to previous state.
- **Self-update**: pull the BinMan repo and reinstall itself.
- **Bundle export**: pack bin+apps+manifest for sync/migration.
- **Manifest install**: bulk installs from text or JSON (with `jq`).
- **Generator**: `binman new` scaffolds scripts/apps (bash/python), with optional venv.
- **Wizard**: interactive generator (with README + gitprep support).
- **TUI**: run `binman` with no args → full menu of operations.
- **System mode**: `--system` installs to `/usr/local/*` (requires perms).

Version in this README: **v1.6.4**

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

- **Scripts**: installed as `~/.local/bin/<name>` (extension dropped).
- **Apps**: copied/symlinked into `~/.local/share/binman/apps/<name>` with a shim at `~/.local/bin/<name>`.
- **Versions**: detected from `VERSION=`, `# Version:`, `__version__`, or a `VERSION` file.

Shim looks like:

```
#!/usr/bin/env bash
exec "$HOME/.local/share/binman/apps/<name>/bin/<name>" "$@"
```

---

## Usage

### Global Options

- `--from DIR` — operate on all executables in DIR  
- `--link` — use symlinks instead of copying  
- `--force` — overwrite on install/restore  
- `--git DIR` — pull repo before `update` or `self-update`  
- `--bin DIR` — override bin directory (default `~/.local/bin`)  
- `--apps DIR` — override apps directory (default `~/.local/share/binman/apps`)  
- `--system` — use `/usr/local/*` (global install/uninstall)  
- `--fix-path` — patch PATH into `~/.zshrc` / `~/.zprofile`  
- `--manifest FILE` — bulk install from manifest  
- `--quiet` — reduce chatter  

### Install

```
binman install ./hello.sh
binman install ./tools/resize.py
binman install ./MyApp/                  # expects ./MyApp/bin/MyApp
binman install https://host/script.sh    # remote file
binman install --manifest tools.txt      # bulk install
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

### Update (with optional git pull)

```
binman update ./hello.sh
binman update ./MyApp
binman update --git ~/Projects/MyApp ./MyApp
```

### Doctor

```
binman doctor
binman doctor --fix-path
```

### Backup & Restore

```
binman backup
binman backup my-stash.zip
binman restore binman_backup-20250101-120000.zip
binman restore my-stash.tgz --force
```

### Rollback

```
binman rollback          # latest snapshot
binman rollback <ID>     # specific snapshot
```

### Self-update

```
binman self-update
binman --git ~/Projects/BinMan self-update
```

### Bundle export

```
binman bundle my-env.zip
```

### Test harness

```
binman test hello -- --help
binman test resize -- -v
```

### New (scaffold)

```
binman new tidy.sh
binman new resize.py
binman new MediaTool --app --lang bash
binman new SmartTool --app --lang python --dir ~/Projects/Tools --venv
```

Scaffolded Bash script:

```
#!/usr/bin/env bash
# Description: Hello from script
VERSION="0.1.0"
set -Eeuo pipefail
echo "Hello from <name> v$VERSION"
```

Scaffolded Python script:

```
#!/usr/bin/env python3
# Description: Hello from script
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

Prompts for name, type (single/app), language, directory, author/desc, venv (for python apps), installs optionally, and can init git with `gitprep`.

### TUI

```
binman tui
# or just: binman
```

Menu includes Install, Uninstall, List, Doctor, New, Wizard, Backup, Restore, Self-update, Rollback, Bundle, Test, and System toggle.

---

## Backup & Restore details

- **Backup** uses `.zip` if `zip/unzip` are available, otherwise `.tar.gz`.  
- Contents:  
  - `bin/` → commands from `BIN_DIR`  
  - `apps/` → app directories from `APP_STORE`  
  - `meta/info.txt` → metadata (timestamp, host, BinMan version, dirs)  
- **Restore** merges into current dirs; skips existing unless `--force`.

---

## Dev workflow tips

- **Edit + Update**

```
binman update path/to/script-or-app
rehash 2>/dev/null || hash -r 2>/dev/null || true
```

- Entrypoint rule for apps: must have `bin/<appname>`.  
- Use `--link` for live-edit dev installs.  

---

## Troubleshooting

- Installed? → `binman -h`  
- Not installed? → `./binman.sh -h`  

Common issues:
- **`command not found`** → add `~/.local/bin` to PATH + rehash  
- **`permission denied`** → `chmod +x` before install  
- **app won’t install** → must contain `bin/<name>`  
- **restore didn’t overwrite** → add `--force`  
- **zip/unzip missing** → `doctor` warns, falls back to tar.gz  

---

## Roadmap

- Smarter update metadata
- Bulk git-aware updates
- More bundle/sync flows across machines
- Install hooks (pre/post)
- Binlets (tiny inline scripts)
- Extra UX candy

---

## License

MIT – do crimes (responsibly).
