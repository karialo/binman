# BinMan (Binary Manager)

Because your ~/Downloads folder is not a filing system, champ.

Let’s be honest: your scripts are everywhere. Some live in ~/Desktop, some in ~/Downloads, one’s rotting in ~/Documents/old_stuff/maybe_useful/, and the crown jewel—final2_REALfinal.sh—is hiding on a random USB stick you lost in 2019.

When you do find them, you rename one to “script.sh” because you’re a visionary, then overwrite it by accident two weeks later. Genius.

## BinMan fixes that.

Install your scripts or apps (even multi-file monsters) straight into `~/.local/bin` or your system bin. Suddenly you can run them anywhere—no more “cd into directory, chmod +x, ./script.sh” like a caveman summoning fire.

Update them when you tweak your masterpiece. BinMan is version-aware, so it swaps the old for the new like a well-trained butler.

Uninstall when you realize your brilliant script was actually a crime against humanity, or straight up tried to `sudo rm -rf /*` your box.

### Install from URL

Found some spicy script on GitHub? Just copy the raw link and:

```
binman install https://raw.githubusercontent.com/someguy/wifi-slap/main/wifi-slap.sh
```

Boom. It’s in your bin. Anywhere on your system. Ready to slap Wi-Fi.

List what you’ve got installed, because you definitely forgot.

**Backup & Restore.** Zip your entire bin, yeet it onto a USB, upload it to cloud, carve it into a stone tablet. Restore later like a necromancer performing dark rites.

**Doctor:** checks if everything’s working or if you’ve somehow replaced bash with Minesweeper.

### Comes with friends

Example: `gitprep.sh`.

GitPrep is like repo-in-a-can. Run it in any directory and it’ll:

- Initialize git  
- Add a README and .gitignore  
- Make the first commit  
- Hook up a remote if you want

One command, and your random folder full of horrors is a legit repo. No excuses now.

DIY mode: BinMan has a **wizard** and **scaffolder** to generate your own apps. You can spin up a project with metadata, versioning, README, optional Python venv, and git baked in. It’s like scaffolding, but less construction site and more “hello, here’s your new pet goblin.”

And when you break something? BinMan lets you **roll back**. Yep, it tracks snapshots before changes. Undo your mistakes like a time traveler with slightly better hair.

BinMan is not just a tool. It’s not just a package manager. It’s a lifestyle choice. It’s the line between order and chaos, between `~/Downloads` and digital nirvana.

So… do you keep pretending your system is “organized enough,” or do you let BinMan drag your scripts out of the mud and into the bin.

**DO IT! DO IT NOW!!**

---

## Features

- **Install**: files, app directories, or remote URLs → `~/.local/bin` and `~/.local/share/binman/apps`.
- **Uninstall**: remove a single command or a whole app (shim + store dir).
- **List**: show installed commands & apps with version and docstring (from top comment).
- **Update**: force-reinstall from file/dir; optionally `--git` pull first.
- **Backup/Restore**: snapshot + restore everything, `.zip` or `.tar.gz`.
- **Rollback**: auto-snapshots before changes; roll back to previous state.
- **Self-update**: fetches the project’s raw script and atomically swaps itself.
- **Bundle export**: pack bin+apps+manifest for sync/migration.
- **Manifest install**: bulk installs from text or JSON (with `jq`).
- **Generator / Wizard**: `binman new` + `binman wizard` scaffold scripts/apps across multiple languages (bash/python/node/typescript/deno/go/rust/ruby/php). Python apps can auto-manage a `.venv`.
- **TUI**: `binman` with no args → full menu (fzf pickers for uninstall/test if available).
- **System mode**: `--system` installs to `/usr/local/*` (requires perms).
- **Stress test**: `binman test stress` runs an internal gauntlet to sanity-check behaviors.

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

### App entry / runtime helpers (for installing directories)

- `--entry CMD` — custom entry command for an app dir  
  (e.g. `python3 src/main.py`, `go run ./cmd/tool`, `cargo run --release`, `node ./bin/cli.js`, `bundle exec ./exe/colorls`)  
- `--workdir DIR` / `--cwd DIR` — `cd` into this subdir before running `--entry`  
- `--venv` — for Python apps: create/activate `./.venv` and run inside it  
- `--req FILE` / `--requirements FILE` — requirements file name (default `requirements.txt`)  
- `--python BIN` — Python to bootstrap the venv (default `python3`)  

Heads-up: if you have `fzf` installed, the **Uninstall** and **Test** menus support selection in the TUI.

### Install

```
# Single files (extension dropped)
binman install ./hello.sh
binman install ./tools/resize.py

# URLs still work
binman install https://host/script.sh

# App directories
# BinMan will try to auto-detect an entry:
#   • Python: pyproject console-scripts → python -m pkg, or common files (src/<name>/__main__.py, main.py, …)
#   • Node/TS: package.json {"bin": …} or "scripts.start"; otherwise tsx src/index.ts if present
#   • Deno: deno task start or common main.ts/js
#   • Go: cmd/<app>/main.go (prefers repo name), else main.go → go run …
#   • Rust: Cargo.toml (bin) → cargo run --release
#   • Ruby: exe/<name> or bin/<name> (gems); Gemfile → uses bundler if available
#   • PHP: composer.json "bin": [...]
binman install ./MyApp/

# When auto-detect can’t guess, tell it explicitly:
binman install ./RepoDir --entry 'python3 src/main.py'

# Python app with a managed venv + requirements:
binman install ./Harvester --entry 'python3 tool.py' --venv --req requirements.txt

# Pick a different Python to seed the venv:
binman install ./Tool --entry 'python3 -m tool' --venv --python /usr/bin/python3.11

# Node examples
binman install ./colorizer             # uses package.json "bin" or "scripts.start"
binman install ./node-thing --entry 'node ./bin/cli.js'

# Go example (multi-cmd repo)
binman install ./lazygit-master        # chooses a sensible ./cmd/<app> if found
binman install ./go-proj --entry 'go run ./cmd/proj'

# Rust example
binman install ./ripgrep --entry 'cargo run --release --bin rg'

# Ruby (gem layout)
binman install ./colorls-main          # exe/colorls (uses bundler if present)
binman install ./some-gem --entry 'bundle exec ./exe/some-gem'

# Deno
binman install ./deno-app              # prefers `deno task start` if defined
binman install ./deno-app --entry 'deno run -A main.ts'

# Bulk
binman install --manifest tools.txt
```

Tip: for app installs, BinMan creates a tiny shim in your bin that `cd`s into the app, then runs the detected or provided entry. With `--venv`, Python apps get a local `.venv` that’s created on first run and quietly `pip install -r` if a requirements file is present.

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
# optionally run with a repo dir you want pulled first:
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
binman test stress --verbose
```

### New (scaffold) & Wizard

BinMan can conjure projects in multiple languages:

```
binman new tidy.sh
binman new resize.py
binman new MyGoTool --app --lang go
binman new MyRustyApp --app --lang rust
binman new MyWebby --app --lang node
binman new MyGem --app --lang ruby
binman new MyPhpThing --app --lang php
binman new SmartTool --app --lang python --venv
```

App scaffold layout:

```
<name>/
├─ bin/<name>
├─ src/
└─ VERSION
```

**Wizard (interactive):**

```
binman wizard
```

Prompts for name, type (single/app), language, directory, author/desc, venv (for Python apps), optional install, and can init git with `gitprep`.

### TUI

```
binman tui
# or just: binman
```

Menu includes **Install, Uninstall, List, Doctor, Wizard, Backup, Restore, Self-Update, Rollback, Bundle, Test**, and a **System mode** toggle. With `fzf`, **Uninstall** and **Test** show interactive pickers.

---

## Backup & Restore details

- **Backup** uses `.zip` if `zip/unzip` are available, otherwise `.tar.gz`.  
- Contents:  
  - `bin/` → commands from `BIN_DIR`  
  - `apps/` → app directories from `APP_STORE`  
  - `meta/info.txt` → metadata (timestamp, host, BinMan version, dirs)  
- **Restore** merges into current dirs; skips existing unless `--force`.

---

## Examples

A ready-made `Examples/` folder is included to show typical single-file and app layouts for Bash, Node, Deno/TS, Go, Rust, Ruby, PHP, and Python. Install any of them to see how shims, versions, and entry detection work.

---

## Dev workflow tips

- **Edit + Update**
```
binman update path/to/script-or-app
rehash 2>/dev/null || hash -r 2>/dev/null || true
```

- Entrypoint rule for apps: ideally have `bin/<appname>`.  
- Use `--link` for live-edit dev installs.  

---

## Troubleshooting

- Installed? → `binman -h`  
- Not installed? → `./binman.sh -h`  

Common issues:
- **`command not found`** → add `~/.local/bin` to PATH + rehash  
- **`permission denied`** → `chmod +x` before install  
- **app won’t install** → provide `bin/<name>` or use `--entry`  
- **restore didn’t overwrite** → add `--force`  
- **zip/unzip missing** → `doctor` warns, falls back to tar.gz  

---

## Roadmap

- Smarter update metadata  
- More bundle/sync flows across machines  
- Install hooks (pre/post)  
- Binlets (tiny inline scripts)  
- Extra UX candy  

---

## License

MIT – do crimes (responsibly).
