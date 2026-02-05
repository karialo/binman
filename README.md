# BinMan (Binary Manager)

Because your `~/Downloads` folder is not a filing system, champ. BinMan is the K.A.R.I-approved way to grab your loose scripts, tame your multi-file apps, and make them runnable anywhere without you doing the sacred `cd` dance.

If you are an IT professional: this is a single Bash tool that installs and manages user or system scoped CLI tools, provides versioning, rollback safety, shims, manifests, and a TUI workflow.

If you are a normal human: this is a magic wand that turns random files into proper commands you can run from anywhere.

---

Version in this README: **v1.9.0**

## Table of Contents

- What BinMan Is
- Quick Install
- How It Works
- Repository Layout
- Commands and Usage
- App Detection and Overrides
- Python venv Support
- Manifests and Bulk Installs
- Dev Workflows (Link Mode and Updates)
- Safety, Rollback, and Pruning
- Included Scripts
- Examples Folder
- Tests
- Optional Dependencies
- License

---

## What BinMan Is

BinMan is a personal CLI tool manager written in Bash. It installs and manages:

- **Single-file scripts** (Bash, Python, JS, Ruby, etc.)
- **App directories** (multi-file projects with a real entry point)
- **Remote scripts** (install directly from raw URLs)

It also handles version sniffing, shims, backups, rollbacks, bulk installs, and a TUI for when your brain refuses to parse command flags.

In short: BinMan makes your tiny tools act like real tools without you turning into a full-time sysadmin.

---

## Quick Install

```bash
git clone https://github.com/karialo/binman
cd binman
chmod +x binman.sh
./binman.sh install binman.sh
rehash 2>/dev/null || hash -r 2>/dev/null || true
binman
```

If `binman` is not found:

```bash
echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.zshrc
source ~/.zshrc
```

---

## How It Works

### Install locations

- **Scripts** are copied or linked into `~/.local/bin/<name>` (extension stripped).
- **Apps** live in `~/.local/share/binman/apps/<name>` with a shim in `~/.local/bin/<name>`.
- **System mode** (`--system`) uses `/usr/local/bin` and `/usr/local/share/binman/apps`, and also refreshes a root-visible `/bin/<name>` or `/usr/bin/<name>` symlink when safe.

### Shims (for apps)

BinMan creates a tiny shim for apps so you can run them like normal commands:

```bash
#!/usr/bin/env bash
exec "$HOME/.local/share/binman/apps/<name>/bin/<name>" "$@"
```

### Version detection

BinMan tries to detect versions from:

- `VERSION` files
- Inline markers like `VERSION=`, `# Version:`, or `__version__ =`

### Rollbacks and safety

Every destructive operation snapshots your `bin/` and `apps/` trees into:

`~/.local/share/binman/rollback/<timestamp>/`

You can roll back any time. So yes, you can un-break things without crying.

---

## Repository Layout

- `binman.sh` - the main BinMan script
- `Scripts/` - bundled utility scripts ready to install
- `Examples/` - single-file and app-layout examples for multiple languages
- `tests/` - basic test harnesses
- `Scripts.zip` - zipped bundle of the `Scripts/` folder
- `touchme.txt` - intentionally empty (yes, really)

---

## Commands and Usage

The full command list:

```
binman <install|uninstall|verify|list|update|doctor|docker|new|wizard|tui|backup|restore|self-update|rollback|prune-rollbacks|analyze|bundle|test|version|help>
```

### Install

```bash
# Single file (extension stripped)
binman install ./hello.sh

# URL (raw script)
binman install https://host/path/tool.sh

# App directory (auto-detect entry)
binman install ./MyApp

# App directory (manual entry)
binman install ./RepoDir --entry 'python3 src/main.py'

# Bulk from directory
binman install --from ./Scripts

# System install
binman install --system ./MyApp
```

### Uninstall

```bash
binman uninstall hello
binman uninstall MyApp
```

### Verify (integrity check of installed items)

```bash
binman verify
binman verify hello
binman verify MyApp
```

### List

```bash
binman list
```

If `fzf` is installed, `list` becomes a fuzzy browser with previews.

### Update

```bash
binman update ./hello.sh
binman update ./MyApp
binman update --git ~/Projects/MyApp ./MyApp
```

### Doctor (environment + app checks)

```bash
binman doctor
binman doctor --fix-path
binman doctor MyApp
binman doctor --all --python 3.11
```

### Docker / Podman management

```bash
# Open the Docker TUI (shows only BinMan-managed containers)
binman docker

# Managed service actions
binman docker up MyApp
binman docker down MyApp
binman docker restart MyApp
binman docker logs MyApp --tail 200
binman docker remove MyApp
binman docker nuke MyApp

# One-shot runner
binman docker run MyTool -- --help

# Maintenance
binman docker prune
binman docker orphans
```

### Backup and Restore

```bash
binman backup
binman backup my-stash.zip
binman restore binman_backup-20250101-120000.zip
binman restore my-stash.tgz --force
```

### Rollback and Prune

```bash
binman rollback
binman rollback 20250201-121500
binman prune-rollbacks
```

### Bundle export

```bash
binman bundle my-env.zip
```

### Analyze (disk usage)

```bash
binman analyze
binman analyze --top 10 --root /var
```

### Test harness

```bash
binman test hello
binman test resize -- --help
binman test stress --jobs 8 --verbose --keep
```

### Self-update

```bash
binman self-update
binman --git ~/Projects/binman self-update
```

### Sudo helper

```bash
binman sudo my-tool -- --flag
```

### New (scaffold) and Wizard

```bash
binman new tidy.sh
binman new resize.py
binman new MyGoTool --app --lang go
binman new MyRustyApp --app --lang rust
binman new MyWebby --app --lang node
binman new MyGem --app --lang ruby
binman new MyPhpThing --app --lang php
binman new SmartTool --app --lang python --venv

binman wizard
```

### TUI

```bash
binman tui
binman
```

### Version and Help

```bash
binman --version
binman --help
```

### Global options (for many commands)

```
--from DIR       Operate on all executable files in DIR
--link           Symlink instead of copying (dev workflows)
--force          Overwrite existing files / restore conflicts
--git DIR        Before update: git pull in DIR
--bin DIR        Override bin directory
--apps DIR       Override apps directory
--system         Target system dirs (/usr/local/*)
--fix-path       (doctor) Add ~/.local/bin to shell PATH
--manifest FILE  Bulk install from line list or JSON array
--reindex        Rebuild manifest index before running command
--quiet          Reduce chatter
```

---

## App Detection and Overrides

When you install a directory, BinMan tries to detect the entry point:

- **Python**: `pyproject.toml` console scripts, `src/<name>/__main__.py`, `main.py`, `app.py`, etc.
- **Node/TS**: `package.json` "bin" or "scripts.start"; TS uses `tsx` if available.
- **Deno**: `deno task start`, or common `main.ts`/`main.js` files.
- **Go**: `cmd/<app>/main.go`, else `main.go`.
- **Rust**: `Cargo.toml` binaries, `cargo run --release`.
- **Ruby**: `exe/<name>` or `bin/<name>` (Bundler if Gemfile exists).
- **PHP**: `composer.json` "bin".

If auto-detection fails (or you want control), use:

```bash
binman install ./RepoDir --entry 'python3 src/main.py'
binman install ./RepoDir --entry 'node ./bin/cli.js' --workdir tools
```

---

## Python venv Support

For Python apps, BinMan can manage a private venv:

```bash
binman install ./Harvester --entry 'python3 tool.py' --venv --req requirements.txt
binman install ./Tool --entry 'python3 -m tool' --venv --python /usr/bin/python3.11
```

It will:

- Create `./.venv` on first run
- Install `requirements.txt` or `pyproject.toml` deps (quietly)
- Run the app inside its venv

---

## Manifests and Bulk Installs

You can bulk install from a manifest:

```bash
binman install --manifest tools.txt
```

`tools.txt` can contain:

```
./Scripts/gitprep.sh
./Scripts/sysclean.sh
https://example.com/tool.sh
```

If `jq` is installed, `.json` manifests can be a JSON array:

```json
[
  "./Scripts/gitprep.sh",
  "./Scripts/sysclean.sh"
]
```

---

## Dev Workflows (Link Mode and Updates)

If you are actively editing a tool, use `--link` so changes are live:

```bash
binman install --link ./MyApp
binman install --link ./Scripts/gitprep.sh
```

When you are ready to update a released version:

```bash
binman update ./MyApp
rehash 2>/dev/null || hash -r 2>/dev/null || true
```

---

## Safety, Rollback, and Pruning

Every destructive command creates a snapshot at:

`~/.local/share/binman/rollback/`

Restore to a previous snapshot:

```bash
binman rollback
binman rollback 20250201-121500
```

Prune old snapshots:

```bash
binman prune-rollbacks
```

---

## Included Scripts

These live in `Scripts/`. Install them with:

```bash
binman install ./Scripts/<script>.sh
```

Tip: `Scripts/README.md` contains quick notes where available.

### checksum
Hash or verify files. Auto-detects MD5/SHA1/SHA256/SHA512.

```bash
checksum archlinux.iso
checksum archlinux.iso e3b0...b855
checksum archlinux.iso SHA256:e3b0...b855
checksum archlinux.iso SHA256SUMS
```

### copy
Resumable copy with progress (rsync based).

```bash
copy big.iso /mnt/usb/
copy -n folder/ /backup/
```

### move
Resumable move with verification before deletion.

```bash
move Downloads/ /mnt/backup/
move -n big.iso /mnt/usb/
```

### verify
Checksum + virus scan, with watch mode.

```bash
verify file.iso
verify file.iso SHA256:deadbeef...
verify --watch ~/Downloads
```

### sysclean
Cross-distro system cleanup (dry-run by default).

```bash
sysclean
sysclean --deep --yes
sysclean --top 20 --show-only
```

### flash
Image writer with a wizard, headless Wi-Fi/SSH setup, and optional expand.

```bash
flash raspios.img
flash --verify --expand raspios.img /dev/sdX
flash --headless --SSID "wifi" --Password "pass" --Country US raspios.img /dev/sdX
```

### prep-headless
Prepare a Raspberry Pi boot partition for headless Wi-Fi and SSH.

```bash
prep-headless /dev/sdX1 "MySSID" "MyPass" US
```

### sd-list
List block devices to avoid flashing the wrong drive.

```bash
sd-list
```

### find-pi
Find Raspberry Pi devices on your LAN.

```bash
find-pi
```

### finder
Recursive name finder (current dir or system-wide).

```bash
finder binman
finder --all binman
```

### scanner
Portable network scanner (Pi Zero friendly).

```bash
scanner
scanner --range 192.168.1.0/24 --ports 22,80,443
```

### wifi-scanner
Wireless scanner (nmcli/iw/iwlist fallback).

```bash
wifi-scanner --interface wlan0
wifi-scanner --format json --backend auto
```

### rsync-backup
Quick backup to a mounted device, timestamped.

```bash
rsync-backup ~/Projects /mnt/backup
```

### gitprep
Initialize a git repo and optionally create a GitHub remote.

```bash
gitprep
gitprep --public --proto https
gitprep --no-gh
```

### push
Commit/push with optional semver bump, tags, and GitHub release.

```bash
push -a -m "fix: tidy"
push -v patch -t
push -v minor -t -r
```

### kari-install
Cross-distro package installer wrapper (apt/dnf/pacman/zypper/rpm-ostree).

```bash
kari-install ripgrep fd
kari-install --search neovim
kari-install -n go git
```

### tailscalesetup
Install Tailscale quickly.

```bash
tailscalesetup
```

---

## Examples Folder

`Examples/` includes ready-to-install demos:

- **Single-file scripts**: `hello-bash.sh`, `hello-python.py`, `hello-js.js`, `hello-deno.ts`, `hello-ruby.rb`, `hello-php.php`, `hello-go.go`, `hello-rust_rs/`.
- **App layouts**: `BashApp`, `PythonApp`, `JsApp`, `DenoApp`, `GoApp`, `RustApp`, `RubyApp`, `PhpApp`.
- **Prebuilt binaries**: `hello-go`, `hello-rust`, `hello-deno` (wrapper).

Usage examples:

```bash
binman install Examples/hello-bash.sh
binman install Examples/hello-python.py
binman install Examples/GoApp
binman install Examples/RustApp
```

---

## Tests

`tests/uninstall.sh` verifies uninstall behavior for shims and backup copies:

```bash
bash tests/uninstall.sh
```

---

## Optional Dependencies

BinMan is Bash-only, but it integrates with optional tools:

- `fzf` for fuzzy list and TUI selection
- `bat` or `tree` for prettier previews
- `zip`/`unzip` or `tar` for backup/restore
- `jq` for JSON manifests
- `git` and `gh` for self-update and repo workflows
- `docker` or `podman` for container management
- Language runtimes for apps (python, node, deno, go, rust, ruby, php)

If you do not have them, BinMan simply downgrades politely and keeps working.

---

## License

MIT. Do crimes (responsibly).
