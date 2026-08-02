# BinMan (Binary Manager)

Because `~/Downloads` is not a filing system, champ.

BinMan turns loose scripts and small multi-file projects into commands you can
run from anywhere. It is written in Bash, prefers boring portable tools, and
has enough K.A.R.I. attitude to stop your toolbox becoming a landfill.

This README has two layers throughout:

- **Noob mode** explains the idea and gives the shortest useful command.
- **Pro mode** explains what BinMan actually does, where files go, what can
  fail, and which assumptions the implementation makes.

If you only want to install something, start with Noob mode. If you are
debugging, automating, packaging, or deciding whether to trust an operation,
read Pro mode too.

Version documented here: **v1.9.0**

## Table of Contents

- [What BinMan Is](#what-binman-is)
- [Quick Start](#quick-start)
- [How BinMan Stores Things](#how-binman-stores-things)
- [Command Reference](#command-reference)
- [App Detection and Python Environments](#app-detection-and-python-environments)
- [Bulk Installs and Manifests](#bulk-installs-and-manifests)
- [Safety, Backups, and Rollbacks](#safety-backups-and-rollbacks)
- [Bundled Scripts](#bundled-scripts)
- [Examples](#examples)
- [Testing and Troubleshooting](#testing-and-troubleshooting)
- [Dependencies and Portability](#dependencies-and-portability)
- [License](#license)

---

## What BinMan Is

### Noob mode

BinMan installs scripts, app directories, and remote scripts as ordinary
commands. Give it a file or project, and it puts a runnable command in your
user bin directory.

```bash
binman install ./my-tool.sh
my-tool
```

It can also browse installed tools, install the bundled utilities in
`Scripts/`, make backups, restore them, and open a friendly terminal interface.

### Pro mode

BinMan is one Bash executable, `binman.sh`, with these core behaviors:

- A single file is copied to `~/.local/bin/<basename-without-last-extension>`.
- A directory is copied to
  `~/.local/share/binman/apps/<name>` and exposed through a shim in
  `~/.local/bin/<name>`.
- A URL is downloaded to a temporary directory and then treated as a single
  file. Downloads use `curl` or `wget`.
- `--system` changes the destinations to `/usr/local/bin` and
  `/usr/local/share/binman/apps`; system installs may re-exec through `sudo`.
- Versions are read from a directory `VERSION` file, or from simple markers
  such as `VERSION=`, `# Version:`, and `__version__ =`.
- The inventory cache lives under `${XDG_STATE_HOME:-~/.local/state}/binman`.

BinMan is a manager for personal tools, not a replacement for a distro package
manager. It does not build every project automatically, and it cannot change
the parent shell's command hash table from inside a child process. After an
install it refreshes its own shell process and prints the appropriate parent
shell command (`rehash` or `hash -r`).

---

## Quick Start

### Noob mode

Install BinMan itself:

```bash
git clone https://github.com/karialo/binman.git
cd binman
chmod +x binman.sh
./binman.sh install ./binman.sh
```

Refresh the command lookup in your current shell when BinMan asks:

```bash
rehash 2>/dev/null || hash -r 2>/dev/null || true
binman
```

If the command is still not found, add the user bin directory to your PATH:

```bash
export PATH="$HOME/.local/bin:$PATH"
```

For persistence, put that export in the startup file used by your shell, or
run `binman doctor --fix-path`.

### Pro mode

The installer is interactive when both stdin and stdout are TTYs. In a
non-interactive command, a single file can be installed directly, but a project
directory requires an explicit entry command:

```bash
binman install ./tool.sh
binman install ./MyApp --entry 'python3 src/main.py' --workdir src
```

The command itself must already be executable or have a usable interpreter
shebang when BinMan is choosing a conventional entry. The installed command
name is derived from the final path component with its last extension removed;
interactive installs can override that name.

The refresh message is not a failure. A program launched as `binman` is a child
of Bash, Zsh, Fish, or another shell and cannot mutate the parent's in-memory
hash table. A shell function wrapper can make that refresh automatic, but
BinMan does not edit shell startup files merely to install a command.

---

## How BinMan Stores Things

### Noob mode

User installs go here:

```text
~/.local/bin/                         commands and app shims
~/.local/share/binman/apps/           copied app directories
~/.local/share/binman/source/         cached repository used by `binman scripts`
~/.local/state/binman/                inventory and state
~/.local/share/binman/rollback/       optional rollback snapshots
```

You normally only need to put `~/.local/bin` in PATH.

### Pro mode

Single-file installs are atomic-ish: BinMan stages a temporary file, checks
Bash syntax when the file looks like a shell script, makes it executable, and
moves it into the target bin directory. Existing files are not replaced unless
`--force` is supplied.

App installs have two layers:

1. The project payload is stored under the app store.
2. A small Bash shim changes into the configured working directory and executes
   the configured entry command with the user's arguments.

For a conventional app containing `bin/<name>`, the shim executes that file.
For a detected or manually supplied command, the shim reconstructs the command
and then uses `exec`, so signals and the exit status belong to the real tool.

`--link` changes directory-app storage from a copied tree to a symlink. It is
intended for development workflows. Ordinary single-file installs are still
copied; `--link` does not turn those into symlinks.

System mode uses `/usr/local/bin` and `/usr/local/share/binman/apps`. When safe,
BinMan also maintains a root-visible symlink in `/usr/bin` or `/bin`; it only
removes a symlink if it can prove that the link points at BinMan's own system
shim.

---

## Command Reference

The complete top-level command set is:

```text
install scripts uninstall verify list update doctor docker new wizard tui
backup restore self-update rollback prune-rollbacks analyze bundle test sudo
version help
```

Global flags can appear before the command, and `--system` is also accepted
after an install target.

### `install`

#### Noob mode

```bash
binman install ./hello.sh
binman install ./MyApp
binman install https://example.org/tool.sh
binman install --from ./Scripts
binman install --system ./MyApp
```

Install one file, one directory, one URL, or all executable files in a
directory. Use the interactive wizard if you need to choose an app entry.

#### Pro mode

```text
binman install TARGET [--entry COMMAND] [--workdir DIR]
                    [--venv] [--req FILE] [--python INTERPRETER]
                    [--name NAME] [--link] [--force] [--system]
binman install --from DIR [--link] [--force]
binman install --manifest FILE [--force]
```

`--from` scans for executable files only. It does not recursively install
every file in a tree. A text manifest ignores blank lines and `#` comments;
JSON manifests are accepted when `jq` is available and are expected to contain
an array of strings or objects with a `source` field.

Remote targets are fetched into a temporary directory. BinMan does not provide
cryptographic verification for a URL before installing it; verify remote
content yourself when that matters.

Single-file Python targets receive special handling: BinMan creates a stable
payload under `~/.config/<name>/app.py`, creates a venv under that directory,
and installs a neighboring `requirements.txt` when present. Directory apps
use the app-store venv flow described in [Python environments](#app-detection-and-python-environments).

### `uninstall`

#### Noob mode

```bash
binman uninstall hello
binman uninstall MyApp
binman uninstall --dry-run hello MyApp
```

Remove a command or app. Use `--dry-run` when you want to see the plan first.

#### Pro mode

BinMan checks the active user or system target, removes the app payload and its
shim when the name identifies an app, and removes a command file otherwise.
For compatibility, `hello.sh` can resolve to an installed `hello`; a literal
`.bak` name is never silently stripped. Destructive uninstalls create a
snapshot only when `BINMAN_AUTO_BACKUP=1` is enabled.

### `verify`

#### Noob mode

```bash
binman verify
```

Check all installed items.

#### Pro mode

For commands, verification checks that the installed path exists and is
executable. For apps, it checks the stored app directory, the expected
`bin/<name>` entry, and the shim. It does not execute the program, test its
dependencies, or compare it with the original source checksum. The current
top-level dispatcher runs the all-items path; although the internal verifier
has name-filtering logic, positional names are not currently forwarded by the
public `verify` command. Failures use a non-zero status.

### `list`

#### Noob mode

```bash
binman list
```

See installed commands and versions. With `fzf`, the list becomes a searchable
browser with previews.

#### Pro mode

The inventory scans user and system command/app stores, prefers an app record
over a same-named shim, extracts metadata, and writes a cache under the BinMan
state directory. The plain list hides app directories unless
`BINMAN_INCLUDE_APPS=1`; the fuzzy browser can show richer previews. Versions
may be `unknown` when no supported marker is present.

### `scripts`

#### Noob mode

```bash
binman scripts
```

Browse the bundled utilities. `fzf` gives you search and a preview pane;
without it, BinMan uses a numbered menu.

#### Pro mode

The command reads from the cached repository at
`~/.local/share/binman/source/Scripts`. A fresh install may not have that cache;
run `binman self-update` from an installed copy or run BinMan from a repository
checkout. The selected row carries name, version, absolute path, and
description metadata; BinMan installs the actual third field, the script path.

### `update`

#### Noob mode

```bash
binman update ./hello.sh
binman update ./MyApp
```

Reinstall a tool from its source and overwrite the installed copy.

#### Pro mode

`update` sets `FORCE=1` and routes through the normal installer, so app entry
detection and Python handling are reused. `--from` can update all executable
files in a directory. A rollback snapshot is taken only when automatic
backups are enabled. The help banner still mentions a `--git` option, but the
current parser does not wire that option into the public update command.

### `doctor`

#### Noob mode

```bash
binman doctor
binman doctor --fix-path
binman doctor MyApp
binman doctor --all --python 3.11
```

Doctor reports paths and optional tools, fixes PATH configuration, and can
prepare Python apps.

#### Pro mode

With no target, Doctor prints the active mode, bin directory, app store, archive
tool availability, PATH status, and possible `binman` shadowing, then lets an
interactive user choose an app. `--all` processes every installed app;
`--dry-run` reports planned Python work. Python apps get a `.venv`, pip is
updated best-effort, and dependencies come from `requirements.txt` or a basic
`pyproject.toml` dependency list. An executable `.binman/doctor.sh` hook is run
from the app directory.

`--fix-path` appends the user-bin export to existing `.zshrc`, `.zprofile`,
`.bashrc`, and `.profile` files, and adds a Fish config entry when Fish is
installed. It does not reload the current shell.

### `docker`

#### Noob mode

```bash
binman docker
binman docker up MyApp
binman docker logs MyApp
binman docker shell MyApp
binman docker down MyApp
```

BinMan can manage containers for installed apps when Docker or Podman is
available.

#### Pro mode

```text
binman docker up|down|restart|logs|follow|shell|edit|build|remove|nuke|purge APP
binman docker run APP -- COMMAND [ARGS...]
binman docker prune
binman docker orphans
```

Metadata is stored under `~/.local/share/binman/docker` unless
`BINMAN_DOCKER_DIR` overrides it. `--engine docker|podman` chooses the backend;
otherwise BinMan detects a usable engine. `up` creates or starts a managed
service, `build` builds from the app metadata root, `edit` changes ports,
mounts, environment, restart policy, and network, `run` performs a one-shot
execution, and `nuke` removes the managed container and image. `purge` removes
BinMan metadata for an app. These commands affect real containers and images;
read the preview before using `remove`, `nuke`, or `prune`.

### `backup` and `restore`

#### Noob mode

```bash
binman backup
binman backup my-tools.zip
binman restore my-tools.zip
```

Back up installed commands and apps, then merge them back later.

#### Pro mode

In a TTY, `binman restore` opens BinMan's archive picker; in a non-TTY it
accepts the archive path directly. The help banner currently advertises a
`--restore FILE` convenience form, but the current top-level option parser does
not dispatch that form, so use the `restore` command and provide the path in a
non-TTY/scripted context.

Backups prefer ZIP when both `zip` and `unzip` exist; otherwise they use
`.tar.gz`. The archive contains `bin/`, `apps/`, and `meta/info.txt` with the
BinMan version, paths, timestamp, and host information. Restore accepts `.zip`,
`.tar.gz`, and `.tgz`, detects a top-level wrapper directory, merges `bin/` and
`apps/`, and restores executable bits. Restore is not a package lockfile and
does not restore external dependencies or a shell's PATH.

### `rollback` and `prune-rollbacks`

#### Noob mode

```bash
BINMAN_AUTO_BACKUP=1 binman install ./tool.sh
binman rollback
binman prune-rollbacks
```

Rollback returns the latest saved BinMan state. Prune removes old snapshots.

#### Pro mode

Automatic snapshots are **disabled by default**. Set `BINMAN_AUTO_BACKUP=1`
before install, update, uninstall, restore, or other mutating flows to save
`bin/`, `apps/`, and metadata under:

```text
~/.local/share/binman/rollback/<timestamp>/
```

`BINMAN_ROLLBACK_KEEP` defaults to 20 snapshots when pruning. `rollback` in the
current command dispatcher applies the latest snapshot; the interactive TUI
can select a specific timestamp. Restore/rollback merges files and does not
delete unrelated newer files.

### `bundle`

#### Noob mode

```bash
binman bundle my-environment.zip
```

Export your installed commands and apps into a portable archive.

#### Pro mode

The bundle contains `bin/`, `apps/`, and `manifest.txt`. ZIP is used when
available; otherwise the output becomes a `.tar.gz`. This is a payload bundle,
not a full machine image: it does not include package-manager state, language
runtimes, Docker images, or shell configuration.

### `analyze`

#### Noob mode

```bash
binman analyze
binman analyze --top 10 --root /var
```

See large directories and files so you know what is eating the disk.

#### Pro mode

Analyze prints `df -hT`, the largest `du -xhd1` directories, and the largest
files found with `find -xdev`. It skips `/proc`, `/sys`, `/dev`, and `/run` in
the file scan and may use the configured sudo helper for unreadable locations.
It does not delete anything; use `sysclean` for interactive cleanup.

### `new`, `wizard`, and `tui`

#### Noob mode

```bash
binman new tidy.sh
binman new MyTool --app --lang python --venv
binman wizard
binman
```

Use `new` for a quick scaffold, `wizard` for guided project creation, and
`binman` with no arguments for the full terminal menu. The help banner lists
`tui`, but the current action dispatcher does not expose a separate `tui`
subcommand.

#### Pro mode

The generator supports Bash, Python, Node, TypeScript, Go, Rust, Ruby, and PHP
templates, plus single-file or app layouts. The wizard collects name, type,
language, directory, description, author, and optional Python venv settings;
it can install the result, create a BinMan manifest, and initialize Git. The
GitHub step prints or uses the available Git tooling; it does not ask BinMan to
invent credentials.

The TUI is a wrapper over the same install, uninstall, list, doctor, Docker,
backup, restore, self-update, rollback, bundle, and test functions. `fzf` adds
search, previews, multi-selection, and keyboard navigation. `BINMAN_NO_CLEAR=1`
or `--no-clear` prevents screen clearing.

### `test`, `sudo`, `version`, and `help`

#### Noob mode

```bash
binman test copy -- --help
binman test stress --quick
binman sudo my-tool -- --root-mode
binman --version
binman --help
```

Test checks a command; sudo runs an installed tool through `sudo`; help and
version explain what BinMan is running.

#### Pro mode

`binman test NAME [-- ARGS]` resolves an installed command and runs it with
`--help` unless explicit arguments follow `--`. `test stress` creates temporary
fixtures and exercises copy, link, app, manifest, uninstall, PATH, weird-name,
backup, and restore paths; `--quick` shortens the run, `--jobs` controls stress
parallelism, `--verbose` prints more detail, and `--keep` preserves fixtures.
The stress harness needs a real TTY in some interactive entry paths.

`binman sudo NAME [ARGS...]` executes the installed command through `sudo`; it
does not make the install itself system-wide. `--help`, `--version`,
`--quiet`, `--no-clear`, `--reindex`, `--engine`, and `--system` are parsed as
top-level options where applicable.

---

## App Detection and Python Environments

### Noob mode

Install a project directory and BinMan tries to find the thing that should run:

```bash
binman install ./PythonTool
binman install ./PythonTool --entry 'python3 src/main.py'
binman install ./PythonTool --entry 'python3 -m tool' --venv
```

If BinMan cannot decide safely, choose an entry in the wizard or provide
`--entry` yourself.

### Pro mode

Detection is heuristic and language-aware. It recognizes metadata from
`pyproject.toml`, `setup.cfg`, `setup.py`, `package.json`, `deno.json`,
`Cargo.toml`, `go.mod`, `Gemfile`/gemspec, and `composer.json`.

The main conventions are:

| Project | Preferred detected command |
|---|---|
| Python | console scripts, package `__main__.py`, `src/main.py`, `main.py`, `app.py`, `cli.py` |
| Node/TypeScript | `package.json` `bin`, then `scripts.start`, then common source files |
| Deno | `deno task start`, then `main.ts`, `mod.ts`, or JavaScript equivalents |
| Go | `cmd/<name>/main.go`, then root `main.go` |
| Rust | first Cargo binary, then `cargo run --release` |
| Ruby | `exe/<name>`, `bin/<name>`, or `main.rb`, with Bundler when available |
| PHP | Composer `bin`, `public/index.php`, `index.php`, or `src/main.php` |

When selection is needed, BinMan ranks likely files by names such as `main`,
`app`, `cli`, `run`, and `start`, executable bits, shebangs, and locations such
as `bin/`, `src/`, and `cmd/`. A heuristic is not proof; use `--entry` for
production or automation.

For app venv mode, BinMan creates `<stored-app>/.venv` on first execution,
installs `--req FILE` or a neighboring `requirements.txt`, changes to
`--workdir` when supplied, and replaces a leading `python`/`python3` command
with the venv interpreter. Dependency installation is best-effort in generated
shims, so inspect failures rather than assuming the app is healthy.

---

## Bulk Installs and Manifests

### Noob mode

```bash
binman install --from ./Scripts
binman install --manifest tools.txt
```

`tools.txt` can contain one local path or URL per line:

```text
./Scripts/checksum.sh
./Scripts/gitprep.sh
https://example.org/tool.sh
```

### Pro mode

`--from DIR` installs the executable regular files directly in that directory;
the operation is not a recursive project builder. A line manifest strips
comments beginning with `#` and ignores blank lines. A `.json` manifest is
parsed with `jq` as an array; each item may be a string or an object whose
`source` property is used.

Bulk operations reuse the same single-file installer, including Bash syntax
validation, Python single-file venv handling, conflict behavior, and status
events. One bad target does not necessarily prevent later targets from being
attempted; inspect the final exit status and output.

---

## Safety, Backups, and Rollbacks

### Noob mode

Before trying risky operations:

```bash
export BINMAN_AUTO_BACKUP=1
binman install --force ./tool.sh
binman backup before-experiment.zip
```

For scripts that can erase disks, delete repositories, alter networking, or
install packages, read their Pro section below and run their help command
first. K.A.R.I. is witty; `rm -rf` remains extremely literal.

### Pro mode

BinMan's own destructive operations are conservative about conflicts unless
`--force` is supplied, and automatic snapshots are opt-in. Archives and
snapshots are local copies, not encrypted backups. They may contain executable
code and host/path metadata, so protect them appropriately.

The bundled scripts are separate programs. BinMan does not sandbox them: once
installed, they run with the permissions of the invoking user and may call
`sudo`, package managers, `mount`, `ip`, `nft`, `ssh`, `git`, Docker, or remote
installers. Use `--dry-run` where available and inspect source before running
as root.

---

## Bundled Scripts

The scripts live in `Scripts/` and can be installed individually:

```bash
binman install ./Scripts/checksum.sh
```

Or browse them:

```bash
binman scripts
```

The descriptions below are based on the current implementation and its actual
help text, not on marketing promises from an earlier K.A.R.I. fever dream.

### `checksum`

#### Noob mode

Calculate or check a file hash:

```bash
checksum image.iso
checksum image.iso SHA256:deadbeef...
checksum image.iso image.iso-CHECKSUM
```

#### Pro mode

`checksum` prints SHA-256 by default. Verification accepts raw hashes, an
`algo:hash` prefix, common GNU checksum lines, BSD lines such as
`SHA256 (file) = hash`, or a checksum file containing a matching basename.
Hash length selects MD5/SHA-1/SHA-256/SHA-512; supported tools must exist as
`md5sum`, `sha1sum`, `sha256sum`, or `sha512sum`. Exit status is 0 for success,
1 for mismatch, and 2 for usage/dependency errors.

### `copy`

#### Noob mode

Copy with progress and resume support:

```bash
copy big.iso /mnt/usb/
copy --dry-run folder/ /backup/
```

#### Pro mode

`copy [--dry-run|-n] SRC... DEST` requires `rsync` and uses `-aHAX`,
`--partial`, `--inplace`, human-readable output, and `--info=progress2`. The
destination is created when needed. Multiple sources require an existing
destination directory. It preserves more metadata than a plain `cp`, so use
the dry run and understand the permissions of the destination.

### `move`

#### Noob mode

Move with a transfer check before deleting the source:

```bash
move Downloads/file.iso /mnt/backup/
move --dry-run Downloads/ /mnt/backup/
```

#### Pro mode

`move [--dry-run|-n] SRC... DEST` uses `rsync` to transfer, then performs a
checksum-based dry-run comparison. It deletes each source only when rsync
reports no required changes. Verification checks that the source is represented
at the destination; it does not remove unrelated extra files already there.
Directories are removed with `rm -rf --one-file-system` after success. A
verification mismatch returns status 3 and leaves the source in place.

### `verify`

#### Noob mode

Check a file and optionally scan it:

```bash
verify file.iso
verify file.iso SHA256:deadbeef...
verify --watch ~/Downloads
```

#### Pro mode

This is a separate checksum/ClamAV tool from BinMan's own `binman verify`.
It accepts a file, directory, expected checksum, checksum file, or recursive
watch mode. Directories skip checksum comparison but can still be scanned.
Watch mode focuses on new files, ignores common temporary downloads and
checksum manifests, and can run verbosely. When available it uses `clamscan`
for malware checks; missing optional scanners reduce coverage rather than
creating a security guarantee.

### `sysclean`

#### Noob mode

Inspect cleanup candidates safely first:

```bash
sysclean
sysclean --show-only --top 20
sysclean --dry-run --deep
```

Actually perform selected cleanup only when you mean it:

```bash
sysclean --deep --yes
```

#### Pro mode

`sysclean` is dry-run by default. It reports disk use and interactively offers
cleanup for package caches/orphans, system journals, developer caches, and
Steam/Heroic/Lutris footprints. `--deep` adds heavier categories; `--no-pkg`
and `--no-steam` disable categories; `--top N` controls large-file reporting;
`--raw` avoids human-readable sizes. `--yes` enables actions, while
`--show-only` only reports. Exact actions depend on detected distro tools, so
review the proposed paths before confirming.

### `flash`

#### Noob mode

Use the wizard for a disk image:

```bash
flash raspios.img
```

Or use direct mode only when you have positively identified the device:

```bash
flash --verify --expand raspios.img /dev/sdX
```

#### Pro mode

`flash` writes compressed or uncompressed images to a block device and can
verify, expand, configure Raspberry Pi headless Wi-Fi/SSH, and stage USB gadget
networking. Direct options include `--verify`, `--expand`, `--gadget`,
`--no-gadget`, `--headless`, `--SSID`, `--Password`, `--Country`, `--Hidden`,
`--User`, and `--UserPass`. `--diagnose-mounts [boot] [root]` inspects already
mounted partitions. The script detects modern `boot/firmware` and older boot
layouts, writes NetworkManager or fallback network configuration, and may
create first-boot/systemd helpers. It requires root-level operations and can
destroy the selected device; never trust `/dev/sdX` as a literal example.

### `prep-headless`

#### Noob mode

Stage SSH and Wi-Fi files on a mounted boot partition:

```bash
prep-headless /dev/sdX1 "MySSID" "MyPassword" GB
```

#### Pro mode

The script mounts the supplied boot partition into a temporary directory using
`sudo`, creates an empty `ssh` marker, writes `wpa_supplicant.conf` with the
country and WPA-PSK network, syncs, and unmounts. It expects at least a boot
partition, SSID, and PSK; country defaults to `GB`. It does not validate that
the partition is the right device or support hidden-network options.

### `sd-list`

#### Noob mode

List likely removable/NVMe whole disks before flashing:

```bash
sd-list
```

#### Pro mode

The script runs `lsblk` for name, size, model, rotation, type, and mountpoint,
then prints `disk` rows whose names contain `sd`, `mmcblk`, or `nvme`. It is a
candidate list, not a complete removable-device classifier; confirm with
`lsblk` yourself before using `flash`.

### `find-pi`

#### Noob mode

Find Raspberry Pi devices on the local network:

```bash
find-pi
```

#### Pro mode

If `arp-scan` exists, the script runs `sudo arp-scan --localnet` and filters
Raspberry Pi names and common Pi MAC prefixes. Otherwise it falls back to
`sudo nmap -sn` over the host's global IPv4 ranges, with short timeouts, and
filters Raspberry-related output. It needs `arp-scan` or `nmap`, plus `ip` for
the fallback. Results are heuristic and may miss a Pi with no identifying
hostname.

### `finder`

#### Noob mode

Find names below the current directory:

```bash
finder binman
finder --all binman
```

#### Pro mode

`finder [--all] [--tags] PATTERN` uses `find -iname '*PATTERN*'` and sorts the
paths. `--all` elevates with sudo and searches `/`; `--tags` is currently a
placeholder flag and does not add tag search behavior. It searches names, not
file contents, and suppresses find errors.

### `findinfiles`

#### Noob mode

Search file contents, usually case-insensitively:

```bash
findinfiles "token"
findinfiles --root /etc "PermitRootLogin"
findinfiles --ext py,js,md --files-with-matches TODO
```

#### Pro mode

This bundled script is Python 3, despite its `.sh` filename. It walks the
current directory, `/` with `--all`, or `--root DIR`; skips noisy directories
and common binary extensions by default; ignores files larger than 5 MB by
default; and also detects NUL bytes in the first 4 KiB. `--case` enables
case-sensitive matching, `--ignore-case` documents the default, `--ext` filters
extensions, `--no-skip` disables default directory skipping, `--skip-dir` and
`--skip-ext` add exclusions, `--max-size` changes the MB limit, `--context N`
prints nearby lines, `--count` reports counts, `--files-with-matches` prints
paths, and `--no-color` disables ANSI output. It returns 0 when it finds a
match and 1 when it finds none.

### `scanner`

#### Noob mode

Scan a local network for responsive hosts and common ports:

```bash
scanner --range 192.168.1.0/24 --ports 22,80,443
```

#### Pro mode

`scanner` performs bounded ICMP and TCP probes with worker concurrency. Options
are `--concurrency`, `--ports`, `--ping-timeout`, `--tcp-timeout`, `--range`,
`--verbose`, `--quiet`, and `--no-color`. Defaults are 100 workers, one-second
timeouts, and ports 22, 80, 443, 5900, 8080, 111, and 5000. If no range is
provided it tries to derive one from local IPv4 configuration. It is an
inventory scanner, not a stealth tool and not a vulnerability assessment.

### `wifi-scanner`

#### Noob mode

Scan nearby Wi-Fi networks:

```bash
wifi-scanner
wifi-scanner --interface wlan0 --backend iw
wifi-scanner --format json --no-color
```

#### Pro mode

The scanner selects `nmcli`, `iw`, or `iwlist` automatically, or accepts a
forced backend. It supports `--interface`, `--backend nmcli|iw|iwlist|auto`,
`--format table|csv|json`, `--no-color`, `--verbose`, `--quiet`, and `--strict`.
It can use `fzf` for interface selection. Backend capabilities differ: signal,
channel, security, and hidden-network fields are only as good as the selected
system tool. It scans; it does not connect to networks.

### `netdiag`

#### Noob mode

Inspect a host's network setup:

```bash
netdiag
netdiag --full --iface usb0
netdiag --quick --json
```

#### Pro mode

`netdiag` covers interfaces, addresses, routes, firewall state, kernel and
NetworkManager information, and a connectivity sanity check. `--quick` is the
default; `--full` adds slower and more privileged checks. `--iface` focuses on
one interface, `--target` chooses the ping target, `--no-sudo` forbids
escalation, `--verbose` prints commands, `--json` emits machine-readable data,
`--write-report PATH` writes a text report, and `--support-bundle DIR` writes a
redacted support bundle. A default target may be prompted for or fall back to
`10.0.0.2`, which reflects the Pi USB-gadget workflow.

### `rsync-backup`

#### Noob mode

Create a timestamped backup directory on a mounted destination:

```bash
rsync-backup ~/Projects /mnt/backup
```

#### Pro mode

The command requires exactly `SRC DEST_MOUNT`, confirms the destination is a
directory, creates `backup-YYYYMMDD-HHMM`, and runs `rsync -aHAX --delete` into
it. Because `--delete` is used, the newly created backup directory mirrors the
source rather than accumulating stale files. It does not verify the source is
the intended mount beyond checking that the path is a directory.

### `gitprep`

#### Noob mode

Prepare the current directory as a Git project:

```bash
gitprep
gitprep --no-gh
gitprep --public --proto https
```

#### Pro mode

`gitprep` initializes or reconciles a repository, targets `main` by default,
seeds `README.md` and `.gitignore` when missing, commits a snapshot, and by
default uses `gh` to create or connect a GitHub repository and push. Options
include `--branch`, `--public`, `--private`, `--proto ssh|https`, `--owner`,
`--name`, `--no-push`, and `--no-gh`. Existing GitHub repositories are reused
when found. `--no-gh` is the local-only mode. It changes Git history and may
create a remote, so run it in the intended project directory.

### `gitremove`

#### Noob mode

Preview the repository identity and confirm before deletion:

```bash
gitremove ./old-project
```

#### Pro mode

`gitremove [PATH] [--remote] [--yes]` resolves the containing Git root, prints
the path and origin, then requires the repository name to be typed. It changes
to `/tmp` and removes the local repository directory. `--remote` additionally
requires `gh`, authenticated GitHub access, and a second literal `DELETE`
confirmation before deleting the GitHub repository. `--yes` skips both prompts
and is therefore appropriate only for carefully controlled automation.

### `push`

#### Noob mode

Commit and push a message:

```bash
push "fix: tidy"
push --dry "show me the plan"
```

#### Pro mode

`push` operates in the current Git repository. A plain message stages all
changes, commits, and pushes the current branch. `-a` stages all changes,
`-m MSG` supplies a commit message, `-v patch|minor|major` updates `VERSION`,
`-t` creates and pushes `v<VERSION>`, `-r` creates a GitHub release through
`gh`, and `--dry` reports actions without changing Git. Without a remote it
still commits but skips pushing. Release creation requires a tag and GitHub
CLI access.

### `kinstall`

#### Noob mode

Install or search for packages across the package tools available on the host:

```bash
kinstall ripgrep fd
kinstall --search neovim
kinstall --dry-run go git
```

#### Pro mode

`kinstall` detects `rpm-ostree`, apt, dnf, pacman, or zypper for repository
packages, and optionally Flatpak and Homebrew. It processes packages
independently, skips already-installed items, curates search results, and logs
tab-separated history to `~/.local/state/kari-install/history.log`.

Options are `--search`, `--dry-run`/`-n`, `--yes`, `--fail-fast`,
`--continue-on-error`, `--prefer auto|repo|flatpak|brew`, `--force-source
repo|flatpak|brew`, `--choose`, `--limit N`, and `--full`. Repository installs
use `sudo`; apt may run `apt-get update` once per process. Atomic systems may
prefer Flatpak for GUI classifications. Candidate matching is heuristic, so
use `--choose` or an exact identifier when ambiguity matters.

### `linux_connect`

#### Noob mode

Connect a Linux host to a Raspberry Pi USB gadget:

```bash
sudo linux_connect.sh
sudo linux_connect.sh --persist
```

#### Pro mode

The script detects USB gadget NICs, configures the host side by default as
`10.0.0.1/24`, finds and stabilizes a Pi peer, enables forwarding/NAT through
nftables or iptables, and can open an inline SSH session. `PI_IP` and
`HOST_IP_CIDR` may be supplied as positional arguments or environment values;
`--iface=name` hints the interface, `--upstream=dev` selects the upstream link,
`--persist` installs a systemd service/timer, `--install` copies the script to
`/usr/local/sbin/linux_connect.sh`, and `--uninstall` removes that installation
and units. SSH defaults to user `pi`; it can generate an ed25519 key and offer
to copy it. The script changes live network state and firewall rules, so use
`--no-persist`-style assumptions carefully: inspect the source and be ready to
remove its rules if your host's network policy is strict.

### `refresh-ssh`

#### Noob mode

Remove a stale host key, then optionally connect:

```bash
refresh-ssh 10.0.0.2
refresh-ssh --connect pi@10.0.0.2
```

#### Pro mode

`refresh-ssh [options] HOST` uses `ssh-keygen -R` against
`~/.ssh/known_hosts`, creating that file with mode 600 when absent. `--all`
also removes `[host]:port` and `[host]:22` variants, `--file PATH` selects a
different known-hosts file, `--port PORT` controls the optional connection,
`--connect` runs SSH afterward, and `--quiet` reduces output. It does not
disable strict host-key checking; the next connection still verifies the new
key.

### `flash`-adjacent network helpers: `find-pi`, `sd-list`, and `prep-headless`

#### Noob mode

These are intentionally small helpers for the Pi workflow:

```bash
sd-list
find-pi
prep-headless /dev/sdX1 "SSID" "password" GB
```

#### Pro mode

`sd-list` identifies candidate whole disks, `find-pi` searches local network
output for Pi fingerprints, and `prep-headless` writes boot-partition SSH and
Wi-Fi configuration. They do not share state or validate one another's
results. Treat the device path and discovered hostname/IP as untrusted input
until you confirm it independently.

### `tailscalesetup`

#### Noob mode

```bash
tailscalesetup
```

#### Pro mode

This is deliberately a tiny wrapper around:

```bash
curl -fsSL https://tailscale.com/install.sh | sh
```

It downloads and executes the current official Tailscale installer. That is
convenient but means behavior changes with the remote script and network
availability. Review the upstream installer first if you need a controlled or
auditable deployment; BinMan does not pin a release or verify a checksum here.

---

## Examples

### Noob mode

The `Examples/` directory contains language samples and app layouts:

```bash
binman install Examples/hello-bash.sh
binman install Examples/hello-python.py
binman install Examples/PythonApp
binman install Examples/GoApp
```

### Pro mode

Examples cover Bash, Python, JavaScript, Deno, Go, Rust, Ruby, and PHP, both as
single files and as directories with `VERSION` and `bin/<name>` conventions.
Some examples are wrappers or prebuilt artifacts rather than guaranteed
portable binaries. The app detector uses the same rules described earlier;
when a sample has multiple plausible entries, pass `--entry` explicitly.

---

## Testing and Troubleshooting

### Noob mode

Run syntax and the quick stress test:

```bash
bash -n binman.sh
binman test stress --quick
```

Useful diagnostics:

```bash
binman doctor
binman --reindex list
BINMAN_DEBUG=1 binman list
```

### Pro mode

The built-in stress harness creates temporary fixtures and exercises single-file
copy installs, link-mode apps, app shims, manifests, uninstall, PATH handling,
odd filenames, backup, restore, and related paths. `--jobs N`, `--verbose`,
`--keep`, and `--quick` tune it. Some TUI paths require a real terminal, so a
non-TTY runner may report that `/dev/tty` is unavailable even when the core
installer is healthy.

Common fixes:

| Symptom | Explanation | Fix |
|---|---|---|
| `binman: command not found` | `~/.local/bin` is not in PATH or the shell cached a miss | `binman doctor --fix-path`, reload the shell, then `rehash`/`hash -r` |
| `Bundled scripts are not cached` | No repository source cache exists | Run from a checkout or use `binman self-update` |
| Directory install refuses non-interactively | BinMan cannot safely choose an entry | Add `--entry '...'`, and optionally `--workdir`/`--venv` |
| Installed version is `unknown` | No recognized `VERSION` marker was found | Add a `VERSION` file or supported marker |
| Docker action fails | No usable Docker/Podman engine or metadata | Run `binman doctor`, check `--engine`, and inspect app metadata |
| A bundled script fails immediately | Its runtime or system dependency is absent | Run `<script> --help`, install the named dependency, and rerun |

---

## Dependencies and Portability

### Noob mode

BinMan itself needs Bash and common Unix tools. Optional tools unlock nicer or
more specialized features:

```text
fzf       fuzzy pickers and previews
bat/tree  prettier previews
zip/unzip or tar   archives
jq        JSON manifests
git/gh    self-update and GitHub workflows
docker/podman       containers
language runtimes   Python, Node, Deno, Go, Rust, Ruby, PHP apps
```

If an optional tool is missing, BinMan usually falls back or explains what is
unavailable.

### Pro mode

The core script is Bash-oriented and uses tools such as `awk`, `sed`, `find`,
`sort`, `mktemp`, `install`, `realpath`/fallbacks, and `ps`. Some behavior is
Linux-specific: system directories, `sudo`, `systemd`, `lsblk`, network
interfaces, Docker/Podman, and Pi flashing helpers are not portable to every
Unix or non-Unix host.

Bundled scripts have their own dependencies. `copy` and `move` need `rsync`;
`findinfiles` needs Python 3; network/Pi tools need combinations of `ip`,
`ping`, `nmap`, `arp-scan`, `nmcli`, `iw`, `iwlist`, `ssh`, and `sudo`; Git
helpers need Git and sometimes `gh`; `kinstall` needs whichever backend it is
using; `flash` and `prep-headless` need root-capable mount/block-device tools;
and `tailscalesetup` needs `curl` plus network access. Missing dependencies are
not silently replaced with fake success.

For automation, prefer explicit targets and flags, capture exit statuses, use
`--dry-run` where supported, and avoid relying on TUI prompts.

---

## License

MIT. Do crimes (responsibly).
