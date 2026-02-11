# BinMan Scripts

K.A.R.I's field manual for the `Scripts/` toolbox.

This repo is a practical toolkit for:
- flashing Raspberry Pi images safely,
- prepping headless boot config,
- scanning networks and Wi-Fi,
- verifying downloads,
- moving/copying large data safely,
- cleaning host systems,
- and smoothing day-to-day Git/package workflows.

If you only remember one rule, make it this:
`--dry-run` first, chaos later.

<a id="table-of-contents"></a>
## Table of Contents

1. [Quick Tool Picker](#quick-tool-picker)
2. [Dependency Matrix](#dependency-matrix)
3. [Safety + Design Notes](#safety--design-notes)
4. [Script Reference](#script-reference)
5. [Script: flash.sh](#flash-sh)
6. [Script: prep-headless.sh](#prep-headless-sh)
7. [Script: verify.sh](#verify-sh)
8. [Script: checksum.sh](#checksum-sh)
9. [Script: scanner.sh](#scanner-sh)
10. [Script: wifi-scanner.sh](#wifi-scanner-sh)
11. [Script: find-pi.sh](#find-pi-sh)
12. [Script: refresh-ssh.sh](#refresh-ssh-sh)
13. [Script: finder.sh](#finder-sh)
14. [Script: findinfiles.sh](#findinfiles-sh)
15. [Script: copy.sh](#copy-sh)
16. [Script: move.sh](#move-sh)
17. [Script: rsync-backup.sh](#rsync-backup-sh)
18. [Script: sd-list.sh](#sd-list-sh)
19. [Script: sysclean.sh](#sysclean-sh)
20. [Script: kari-install.sh](#kari-install-sh)
21. [Script: gitprep.sh](#gitprep-sh)
22. [Script: push.sh](#push-sh)
23. [Script: tailscalesetup.sh](#tailscalesetup-sh)
24. [Typical Workflows](#typical-workflows)
25. [Troubleshooting](#troubleshooting)
26. [Final Notes](#final-notes)

## Quick Tool Picker

| Script | Use it when you need to... |
|---|---|
| `flash.sh` | Write a Pi image to SD/USB, stage headless/gadget setup, and diagnose mounted bootfs/rootfs |
| `prep-headless.sh` | Inject only `/boot` headless files on an already-written image |
| `verify.sh` | Do checksum + antivirus in one command, including watch mode |
| `checksum.sh` | Compute/verify checksums (raw, prefixed, or checksum-file formats) |
| `scanner.sh` | Scan a CIDR/subnet for alive hosts and open ports quickly |
| `wifi-scanner.sh` | Scan nearby Wi-Fi networks using `nmcli`/`iw`/`iwlist` |
| `find-pi.sh` | Find Raspberry Pi devices on local network (OUI/vendor detection) |
| `refresh-ssh.sh` | Remove stale `known_hosts` entries and optionally reconnect |
| `finder.sh` | Find files/dirs by name recursively |
| `findinfiles.sh` | Search inside files recursively with filtering and context |
| `copy.sh` | Resumable rsync copy with progress |
| `move.sh` | Resumable rsync move with verification before delete |
| `rsync-backup.sh` | Timestamped rsync backup to mounted destination |
| `sysclean.sh` | Guided cross-distro cleanup (safe by default) |
| `kari-install.sh` | Cross-distro package installer/search wrapper |
| `gitprep.sh` | Initialize repo and wire/create GitHub remote |
| `push.sh` | Add/commit/push with optional semver bump/tag/release |
| `sd-list.sh` | List block devices quickly before flashing |
| `tailscalesetup.sh` | Run Tailscale install script |

## Dependency Matrix

Package names can vary slightly by distro release, but this gets you 95% of the way there.

| Capability | Tools Used By Scripts | Debian / Ubuntu | Fedora | Arch | openSUSE |
|---|---|---|---|---|---|
| Core shell + file utils | almost all scripts | `bash coreutils findutils grep sed gawk util-linux` | `bash coreutils findutils grep sed gawk util-linux` | `bash coreutils findutils grep sed gawk util-linux` | `bash coreutils findutils grep sed gawk util-linux` |
| Flash/decompress images | `flash.sh` | `xz-utils gzip bzip2 zstd` | `xz gzip bzip2 zstd` | `xz gzip bzip2 zstd` | `xz gzip bzip2 zstd` |
| Partition grow/resize | `flash.sh --expand` | `cloud-guest-utils e2fsprogs` | `cloud-utils-growpart e2fsprogs` | `cloud-guest-utils e2fsprogs` | `growpart e2fsprogs` |
| Device/network discovery | `flash.sh`, `scanner.sh`, `find-pi.sh` | `util-linux iproute2 iputils-ping netcat-openbsd nmap arp-scan` | `util-linux iproute iputils nmap-ncat nmap arp-scan` | `util-linux iproute2 iputils openbsd-netcat nmap arp-scan` | `util-linux iproute2 iputils netcat-openbsd nmap arp-scan` |
| Wi-Fi scanning | `wifi-scanner.sh` | `network-manager iw wireless-tools jq fzf` | `NetworkManager iw wireless-tools jq fzf` | `networkmanager iw wireless_tools jq fzf` | `NetworkManager iw wireless-tools jq fzf` |
| Antivirus + watch events | `verify.sh` | `clamav inotify-tools` | `clamav inotify-tools` | `clamav inotify-tools` | `clamav inotify-tools` |
| Git + GitHub release flow | `gitprep.sh`, `push.sh` | `git gh` | `git gh` | `git github-cli` | `git gh` |
| Package-source abstraction | `kari-install.sh` | `flatpak` (optional), `brew` (optional) | `flatpak` (optional), `brew` (optional) | `flatpak` (optional), `brew` (optional) | `flatpak` (optional), `brew` (optional) |

Quick install examples:
```bash
# Debian/Ubuntu baseline
sudo apt update
sudo apt install -y bash coreutils findutils grep sed gawk util-linux \
  rsync xz-utils gzip bzip2 zstd cloud-guest-utils e2fsprogs \
  iproute2 iputils-ping netcat-openbsd nmap arp-scan \
  network-manager iw wireless-tools jq fzf clamav inotify-tools git gh

# Fedora baseline
sudo dnf install -y bash coreutils findutils grep sed gawk util-linux \
  rsync xz gzip bzip2 zstd cloud-utils-growpart e2fsprogs \
  iproute iputils nmap-ncat nmap arp-scan \
  NetworkManager iw wireless-tools jq fzf clamav inotify-tools git gh
```

## Safety + Design Notes

- Most scripts fail fast (`set -e` style) and print clear status output.
- Risky operations are usually guarded by prompts or dry-run defaults.
- `flash.sh` asks for explicit device confirmation twice plus final `YEAH`.
- `sysclean.sh` defaults to dry-run. You must pass `--yes` for destructive actions.
- `move.sh` verifies copy integrity before deleting source.
- `refresh-ssh.sh` intentionally does not disable strict host key checking.
- Several scripts elevate with `sudo` only for the specific privileged step.

## Script Reference

<a id="flash-sh"></a>
### `flash.sh` (v0.9.0)

**Designed for**
- Flashing Raspberry Pi images (`.img`, `.iso`, `.xz`, `.gz`, `.bz2`, `.zst`) to whole devices with strong guardrails.
- Staging headless boot setup (SSH, Wi-Fi, country/regdomain, first-boot user, SPI).
- Optionally staging USB gadget networking (`dwc2` + `g_ether` + `usb0` static IP).
- Running offline diagnostics on mounted `bootfs/rootfs` without reflashing.

**Usage**
```bash
flash.sh <image>
flash.sh [--verify] [--expand] \
  [--gadget|--no-gadget] \
  [--headless --SSID "name" --Password "pass" --Country CC [--Hidden]] \
  [--User NAME --UserPass PASS] \
  <image> <device>

flash.sh --diagnose-mounts [bootfs_mount] [rootfs_mount]
```

**Key options**
- `--verify`: compare first 16 MiB hash of image and flashed device.
- `--expand`: grow the best root-like ext partition with `growpart` + `resize2fs`.
- `--headless`: stage SSH, Wi-Fi, country/regdomain, and first-boot helpers.
- `--gadget` / `--no-gadget`: explicit USB gadget staging toggle.
- `--SSID`, `--Password`, `--Country`, `--Hidden`: headless Wi-Fi settings.
- `--User`, `--UserPass`: optional first-boot user creation/reset via staged trigger + service.
- `--diagnose-mounts`: print the same post-flash diagnostics from mounted `bootfs/rootfs`, no write.

**Examples**
```bash
# Interactive wizard + picker
sudo ./flash.sh ~/Images/raspios.img.xz

# Direct mode with headless + gadget + verify
sudo ./flash.sh --headless --gadget \
  --SSID "Lab AP" --Password "CorrectHorseBatteryStaple" --Country GB \
  --User kali --UserPass kali \
  --verify ~/Images/custom-pi.img.xz /dev/sdb

# Offline diagnostics on already-mounted partitions
./flash.sh --diagnose-mounts /run/media/$USER/bootfs /run/media/$USER/rootfs
```

**How it works**
- Enforces target safety checks:
  - requires whole-disk target, rejects current root disk, double path confirmation, final `YEAH`.
- Detects Pi-like partition layout after write and adapts staging paths.
- Resolves boot files robustly across both layouts:
  - `bootfs/config.txt` and `bootfs/cmdline.txt`
  - `bootfs/firmware/config.txt` and `bootfs/firmware/cmdline.txt`
- Headless staging includes:
  - SSH trigger (`ssh`) in boot root and firmware path when available.
  - `wpa_supplicant.conf` with hidden-SSID support.
  - SPI enable (`dtparam=spi=on`) best-effort.
  - Rootfs country/regdomain persistence.
  - First-boot `wificountry` trigger + `apply-wificountry.service`.
  - NM Wi-Fi profile under `/etc/NetworkManager/system-connections/`.
  - Optional `firstboot-user` trigger + `apply-userconf.service`.
- USB gadget staging (`--gadget`) includes:
  - `dtoverlay=dwc2` in boot config.
  - `modules-load=dwc2,g_ether` in cmdline.
  - Rootfs usb0 IP staging:
    - NM profile preferred (`usb-gadget.nmconnection`, `10.0.0.2/24`, host `10.0.0.1`).
    - fallback `/etc/network/interfaces.d/usb0` when NM is absent.
  - Fallback first-boot modprobe service if gadget boot edits are incomplete.
- Always prints a detailed `POST-FLASH SUMMARY` with staged vs non-staged items and modified targets.

**Important behavior**
- Gadget is opt-in by default (safety-first); interactive flow shows a recommendation and asks.
- `--diagnose-mounts` runs diagnostics only and exits without flashing.
- First-boot helper scripts are tolerant and designed not to brick boot if dependencies are missing.

**Dependencies**
- Required core tools: `dd`, `mount`, `umount`, `partprobe`, `lsblk`, `fdisk`, `awk`, `sed`, `grep`.
- Compression tools as needed: `xz`, `gzip`, `bzip2`, `zstd`.
- Optional: `fzf`, `growpart`/`e2fsck`/`resize2fs`, `iw`, `systemctl` in target image.

<a id="prep-headless-sh"></a>
### `prep-headless.sh` (v0.1.0)

**Designed for**
- Fast post-flash injection of headless files onto a mounted boot partition.

**Usage**
```bash
prep-headless.sh <boot-part> <SSID> <PSK> [COUNTRY]
```

**Example**
```bash
./prep-headless.sh /dev/sdb1 "MyWiFi" "SuperSecret" GB
```

**How it works**
- Mounts the provided boot partition to temp dir.
- Writes `ssh` marker and `wpa_supplicant.conf`.
- Unmounts and cleans temporary mount.

**Notes**
- Lightweight helper, less comprehensive than `flash.sh`.
- Defaults country to `GB`.

<a id="verify-sh"></a>
### `verify.sh` (v0.5.1)

**Designed for**
- One-shot trust check: checksum verification plus ClamAV scan.
- Ongoing directory watch for new files.

**Usage**
```bash
verify.sh <file|dir>
verify.sh <file> <expected-checksum>
verify.sh <file> <checksumfile>
verify.sh --watch <dir> [--verbose]
```

**Examples**
```bash
# Auto-detect checksum file in same directory, then scan
./verify.sh kali.iso

# Verify explicit checksum and scan
./verify.sh kali.iso sha256:abc123...

# Watch downloads folder for new files only
./verify.sh --watch ~/Downloads
```

**How it works**
- Checksum mode:
  - Accepts raw hash, `algo:hash`, pasted hash+filename, or checksum manifest.
  - Auto-detects hash algorithm by length.
  - Can auto-locate likely checksum manifests beside target file.
- Scan mode:
  - Uses `clamscan` if installed.
  - Handles clamscan return codes cleanly under `set -e`.
- Watch mode:
  - Prefers `inotifywait`; falls back to polling.
  - Ignores temp download artifacts and checksum manifests.
  - Deduplicates rapid duplicate events.
  - Waits for file size to settle before scanning.

**Exit codes**
- `0`: verified clean or clean scan.
- `1`: checksum mismatch or infected.
- `2`: usage/error.
- `3`: scan engine error.
- `4`: scan clean but checksum not verified.

<a id="checksum-sh"></a>
### `checksum.sh` (v0.2.0)

**Designed for**
- Lightweight checksum generation and robust verification against common checksum formats.

**Usage**
```bash
checksum.sh <file>
checksum.sh <file> <expected-checksum>
checksum.sh <file> <checksumfile>
```

**Examples**
```bash
./checksum.sh archlinux.iso
./checksum.sh archlinux.iso sha256:deadbeef...
./checksum.sh archlinux.iso "deadbeef...  archlinux.iso"
./checksum.sh archlinux.iso SHA256SUMS
```

**How it works**
- Prints SHA-256 by default in single-arg mode.
- Verification mode supports:
  - GNU checksum lines (`<hash>  <file>`),
  - BSD style (`SHA256 (file) = <hash>`),
  - raw one-line hash files.
- Auto-selects hash tool by digest length (`md5`, `sha1`, `sha256`, `sha512`).

<a id="scanner-sh"></a>
### `scanner.sh` (v1.1.0)

**Designed for**
- Fast subnet host discovery with optional port probing.
- Portable operation on low-power machines (Pi Zero 2W friendly).

**Usage**
```bash
scanner.sh [options]
```

**Key options**
- `-r, --range CIDR`: explicit scan range; auto-detected if omitted.
- `-c, --concurrency N`: parallel workers (default `100`).
- `-p, --ports`: comma-separated ports (default `22,80,443,5900,8080,111,5000`).
- `-t, --ping-timeout`, `-T, --tcp-timeout`.
- `-v`, `-q`, `--no-color`.

**Examples**
```bash
./scanner.sh
./scanner.sh --range 192.168.1.0/24 --ports 22,80,443,445
./scanner.sh --concurrency 200 --quiet
```

**How it works**
- CIDR parsing is pure Bash (no Python/ipcalc required).
- Uses ICMP ping (if present) plus TCP connect checks (`nc` or `/dev/tcp` fallback).
- Aggregates results into summary + table.
- Hard-caps huge scans at 4096 hosts for safety.

<a id="wifi-scanner-sh"></a>
### `wifi-scanner.sh` (v1.0)

**Designed for**
- Portable Wi-Fi survey tool with backend fallback.
- Works across environments where only one of `nmcli`/`iw`/`iwlist` exists.

**Usage**
```bash
wifi-scanner.sh [options]
```

**Key options**
- `-i, --interface IFACE`.
- `-b, --backend nmcli|iw|iwlist|auto` (default `auto`).
- `-f, --format table|csv|json` (default `table`).
- `--verbose`, `--quiet`, `--strict`, `--no-color`, `--no-fzf`.

**Examples**
```bash
./wifi-scanner.sh
./wifi-scanner.sh --interface wlan0 --backend iw
./wifi-scanner.sh --format csv --no-color > wifi.csv
./wifi-scanner.sh --format json > wifi.json
```

**How it works**
- Detects wireless interfaces from `ip`/`/sys/class/net`.
- Uses `fzf` for interface picker when available.
- Backend order in `auto`: `nmcli` -> `iw` -> `iwlist`.
- Elevates only when scan backend needs privilege.
- Normalizes network rows into a consistent schema.
- Outputs pretty table, CSV, or JSON.

**Notes**
- JSON mode is best with `jq` installed.
- Signal may be converted from dBm to percent for table readability.

<a id="find-pi-sh"></a>
### `find-pi.sh` (v0.1.0)

**Designed for**
- Quick discovery of Raspberry Pi devices on local network.

**Usage**
```bash
./find-pi.sh
```

**How it works**
- Preferred path: `arp-scan --localnet` and filter Raspberry Pi OUIs/vendor strings.
- Fallback path: `nmap -sn` network sweep + Raspberry string filtering.

**Dependencies**
- `arp-scan` preferred.
- `nmap` fallback.

<a id="refresh-ssh-sh"></a>
### `refresh-ssh.sh` (v0.1.1)

**Designed for**
- Clean stale SSH host keys when IP reuse causes trust conflicts.
- Optional immediate reconnect once key is refreshed.

**Usage**
```bash
refresh-ssh.sh [options] <host|ip|user@host>
```

**Key options**
- `-c, --connect`: run SSH after refresh.
- `-a, --all`: also remove bracketed host:port entries.
- `-f, --file PATH`: custom known_hosts file.
- `-p, --port PORT`: connect port (default `22`).
- `-q, --quiet`.

**Examples**
```bash
./refresh-ssh.sh 10.0.0.2
./refresh-ssh.sh --all --connect pi@10.0.0.2
./refresh-ssh.sh --file ~/.ssh/known_hosts --connect pwnagotchi
```

**How it works**
- Uses `ssh-keygen -R` (standard safe host key removal).
- Creates known_hosts file if missing.
- Parses `user@host` target or prompts for user when needed.
- Optionally `exec ssh` after cleanup.

**K.A.R.I note**
- Strict host checking stays enabled. Security with manners.

<a id="finder-sh"></a>
### `finder.sh` (v1.0.0)

**Designed for**
- Recursive name search for files/directories from current dir or system root.

**Usage**
```bash
finder.sh [--all] [--tags] <pattern>
```

**Examples**
```bash
./finder.sh binman
./finder.sh --all ssh
```

**How it works**
- Current-dir mode: `find "$PWD" -iname "*pattern*"`.
- `--all`: elevates to sudo if needed, then searches from `/`.
- `--tags`: placeholder for future tag index feature.

<a id="findinfiles-sh"></a>
### `findinfiles.sh` (Python script)

**Designed for**
- Grep-like recursive text search with context, filters, and better defaults.

**Usage**
```bash
findinfiles.sh [options] <term>
```

**Key options**
- Scope: `--all` or `--root DIR`.
- Case: `--ignore-case` (default) or `--case`.
- Filters: `--ext`, `--skip-dir`, `--skip-ext`, `--no-skip`.
- Output: `--context N`, `--count`, `--files-with-matches`, `--no-color`.
- Size guard: `--max-size MB` (default `5`).

**Examples**
```bash
./findinfiles.sh "token"
./findinfiles.sh --root /etc "PermitRootLogin"
./findinfiles.sh --ext py,sh --context 2 "TODO"
./findinfiles.sh --files-with-matches --count "apikey"
```

**How it works**
- Walks files recursively with skip lists for noisy dirs and binary-ish extensions.
- Binary detection by NUL-byte sniffing.
- Highlights matches in color when TTY supports it.
- Returns `0` when matches found, `1` when none.

<a id="copy-sh"></a>
### `copy.sh` (v0.2.0)

**Designed for**
- Reliable resumable copy for big files/directories.

**Usage**
```bash
copy.sh [--dry-run|-n] SRC... DEST
```

**Examples**
```bash
./copy.sh ~/isos /mnt/backup/
./copy.sh -n huge.img /mnt/usb/
./copy.sh file1 file2 /mnt/target_dir/
```

**How it works**
- Uses `rsync -aHAX --partial --inplace --info=progress2`.
- Supports multiple sources.
- Validates destination behavior for multi-source copy.

<a id="move-sh"></a>
### `move.sh` (v0.2.0)

**Designed for**
- Safer `mv` replacement for large/fragile transfers.

**Usage**
```bash
move.sh [--dry-run|-n] SRC... DEST
```

**Examples**
```bash
./move.sh /data/archive.tar /mnt/nas/
./move.sh -n folderA folderB /mnt/storage/
```

**How it works**
- Stage 1: rsync copy with resume/progress.
- Stage 2: rsync checksum dry-run verify.
- Stage 3: delete source only if verify passes.

If verification fails, source is kept and script exits non-zero.

<a id="rsync-backup-sh"></a>
### `rsync-backup.sh` (v0.1.0)

**Designed for**
- Quick timestamped backup directory creation on mounted target.

**Usage**
```bash
rsync-backup.sh SRC DEST_MOUNT
```

**Example**
```bash
./rsync-backup.sh ~/Projects /mnt/backupdrive
```

**How it works**
- Creates `backup-YYYYmmdd-HHMM` dir under destination mount.
- Runs `rsync -aHAX --delete --info=progress2`.

<a id="sd-list-sh"></a>
### `sd-list.sh` (v0.1.0)

**Designed for**
- One-glance block-device listing before you do anything regrettable.

**Usage**
```bash
./sd-list.sh
```

**How it works**
- Prints disk devices with `lsblk` and columns for name, size, model, rota, type, mountpoint.

<a id="sysclean-sh"></a>
### `sysclean.sh` (v1.0.1)

**Designed for**
- Cross-distro cleanup assistant with human-readable reporting.

**Usage**
```bash
sysclean.sh [options]
```

**Key options**
- `--yes`: live mode (actually execute).
- `--dry-run`: preview only (default behavior).
- `--deep`: include package/journal/dev cache cleanup.
- `--show-only`: report without prompts/actions.
- `--top N`: top largest files (default `10`).
- `--no-pkg`, `--no-steam`, `--raw`.

**Examples**
```bash
./sysclean.sh
./sysclean.sh --top 25 --show-only
./sysclean.sh --yes --deep
```

**How it works**
- Detects package manager (`pacman`, `apt`, `dnf`, `zypper`, `apk`, `brew`).
- Shows disk report and top large files.
- Offers selective deletion prompts.
- Reports Steam/Heroic/Lutris footprint.
- Optionally runs deeper package/journal/dev-cache cleanup.

**K.A.R.I note**
- It is a janitor, not a demolition crew. Dry-run is default for a reason.

<a id="kari-install-sh"></a>
### `kari-install.sh` (v0.1.0)

**Designed for**
- Unified package install/search across repo, Flatpak, and Homebrew.
- Especially handy on mixed environments (classic distro + Atomic/Bazzite + Flatpak).

**Usage**
```bash
kari-install.sh [options] <package> [more packages...]
kari-install.sh --search <term> [more terms...]
```

**Key options**
- `-s, --search`: search mode only.
- `-n, --dry-run`: print actions only.
- `-y, --yes`: auto-confirm where supported.
- `--fail-fast` or `--continue-on-error`.
- `--prefer auto|repo|flatpak|brew`.
- `--force-source repo|flatpak|brew`.
- `--choose`: interactive source choice when multiple candidates exist.
- `--limit N`, `--full`: tune search result verbosity.

**Examples**
```bash
./kari-install.sh ripgrep fd
./kari-install.sh --search neovim
./kari-install.sh --prefer flatpak gimp
./kari-install.sh --choose steam
./kari-install.sh --dry-run --force-source brew jq
```

**How it works**
- Detects backend tool (`rpm-ostree`, `apt`, `dnf`, `pacman`, `zypper`).
- Detects optional `flatpak` and `brew`.
- Scores candidates and selects source by availability + preference rules.
- On atomic+GUI scenarios, can prefer Flatpak in auto mode.
- Logs history to `~/.local/state/kari-install/history.log`.
- Search mode prints curated results plus recap.

**Operational details**
- Apt path runs `apt-get update` once per execution before installs.
- Already-installed packages are skipped cleanly per source.
- Non-found packages are skipped with reason instead of hard crash.

<a id="gitprep-sh"></a>
### `gitprep.sh` (v1.2.0)

**Designed for**
- Bootstrap current directory into sane Git repo with optional GitHub wiring.

**Usage**
```bash
gitprep.sh [options]
```

**Key options**
- `--branch NAME` (default `main`).
- `--public` / `--private` (default private).
- `--proto ssh|https` for origin URL style.
- `--owner`, `--name`.
- `--no-push`.
- `--no-gh` for local-only setup.

**Examples**
```bash
./gitprep.sh
./gitprep.sh --public --name cool-tool
./gitprep.sh --owner myorg --name infra-scripts --proto https
./gitprep.sh --no-gh
```

**How it works**
- Initializes/switches branch safely.
- Seeds `README.md` and `.gitignore` if absent.
- Commits initial snapshot.
- If `gh` enabled:
  - detects/creates GitHub repo,
  - sets canonical origin URL,
  - pushes branch (unless `--no-push`).

<a id="push-sh"></a>
### `push.sh` (v1.0.0)

**Designed for**
- One command for stage/commit/push, optionally version/tag/release flow.

**Usage**
```bash
push.sh [-a] [-m "msg"] [-v patch|minor|major] [-t] [-r] [--dry]
```

**Key options**
- `-a`: `git add -A`.
- `-m`: commit message (or opens editor if omitted and staged changes exist).
- `-v patch|minor|major`: bump `VERSION` file semver.
- `-t`: create annotated tag `v<VERSION>`.
- `-r`: create GitHub release using `gh`.
- `--dry`: preview without changing repo.

**Examples**
```bash
./push.sh -a -m "fix: wifi parser"
./push.sh -a -v patch -t
./push.sh -a -v minor -t -r
./push.sh --dry -a -m "chore: test pipeline"
```

**How it works**
- Ensures you are inside a git repo.
- Optionally bumps `VERSION`.
- Commits if staged changes exist.
- Pushes current branch to first remote if present.
- Optional tag push.
- Optional GitHub release notes from commit log.

<a id="tailscalesetup-sh"></a>
### `tailscalesetup.sh` (v0.1.0)

**Designed for**
- One-liner convenience wrapper for installing Tailscale.

**Usage**
```bash
./tailscalesetup.sh
```

**How it works**
- Executes: `curl -fsSL https://tailscale.com/install.sh | sh`

**Caution**
- This is intentionally minimal. Review upstream installer behavior before use in locked-down environments.

## Typical Workflows

### New Pi Image Workflow
```bash
./sd-list.sh
sudo ./flash.sh --headless \
  --SSID "LabWiFi" --Password "SuperSecret" --Country GB \
  --User pi --UserPass raspberry \
  --verify ~/Images/my-pi-image.img.xz /dev/sdb
```

Then discover + connect:
```bash
./find-pi.sh
./refresh-ssh.sh --connect pi@10.0.0.42
```

### Download Trust Workflow
```bash
./checksum.sh kali.iso SHA256SUMS
./verify.sh kali.iso
```

### Safe Data Shuffle Workflow
```bash
./copy.sh /data /mnt/backup/
./move.sh /staging/huge-file.img /archive/
```

### Dev Repo Bootstrap Workflow
```bash
./gitprep.sh --public --name my-new-tool
./push.sh -a -m "feat: first commit"
```

## Troubleshooting

### `flash.sh`

Problem: `No removable disks detected.`
- Check if your adapter/card reader is visible in `lsblk`.
- Use explicit device argument mode: `sudo ./flash.sh image.img.xz /dev/sdX`.
- Some USB readers report `RM=0`; explicit device path bypasses picker filtering.

Problem: `Refusing to flash current root disk`
- Good. This is the script protecting your OS from an accidental speedrun into oblivion.
- Confirm target is not your host boot disk.

Problem: `growpart not found`
- Install:
  - Debian/Ubuntu: `sudo apt install cloud-guest-utils`
  - Fedora: `sudo dnf install cloud-utils-growpart`
  - Arch: `sudo pacman -S cloud-guest-utils`

Problem: Wi-Fi staged but target does not connect on first boot
- Verify staged files on flashed media:
  - boot: `wpa_supplicant.conf`, `wificountry`, `ssh`
  - rootfs: `/etc/wpa_supplicant/wpa_supplicant.conf` contains `country=XX`
  - rootfs: `apply-wificountry.service` and script exist
- If using first-boot user staging, verify trigger name is `firstboot-user` (not `userconf`).
- If image is not systemd-based, service enable may be skipped by design. Boot still proceeds safely.
- For unusual custom images, validate network stack (NetworkManager vs ifupdown vs netplan).

Problem: Host does not see `usb0` after boot
- Run offline diagnostics against mounted media:
  - `./flash.sh --diagnose-mounts /run/media/$USER/bootfs /run/media/$USER/rootfs`
- Check summary for these common blockers:
  - `config.txt` forces host mode (`dr_mode=host` or `otg_mode=1`).
  - `cmdline.txt` missing `modules-load=dwc2,g_ether`.
  - no staged usb0 config in rootfs (NM `usb-gadget.nmconnection` or interfaces fallback).
- If needed, reflash with gadget enabled or pass explicit `--gadget` during direct mode.

Problem: `--diagnose-mounts` fails with mount path errors
- Pass both paths together, not one:
  - `./flash.sh --diagnose-mounts /run/media/$USER/bootfs /run/media/$USER/rootfs`
- Ensure mount points are readable by your user (or run with sudo).

Problem: `SPI config.txt not found (skipping SPI enable)`
- Image may not expose Pi boot config in expected location yet.
- Check boot partition for either:
  - `config.txt`
  - `firmware/config.txt`

### `verify.sh` and `checksum.sh`

Problem: `missing dependency: clamscan` or scan is skipped
- Install ClamAV (`clamav`) if you want malware checks.
- `verify.sh` will still do checksum logic even if scanner is unavailable.

Problem: `RESULT: scan clean, checksum not verified`
- You did not pass checksum input and no matching checksum file was auto-detected.
- Run with explicit checksum or checksum file:
  - `./verify.sh file.iso sha256:...`
  - `./verify.sh file.iso SHA256SUMS`

Problem: Watch mode misses events
- Install `inotify-tools` for event-driven watch.
- Without it, script falls back to polling every few seconds.

### `wifi-scanner.sh`

Problem: `No wireless interfaces detected.`
- Confirm interface exists: `ip -o link show`.
- Check driver state and rfkill.
- Some VMs/containers expose no Wi-Fi hardware directly.

Problem: `iw`/`iwlist` backend fails
- Re-run with `--backend nmcli` if NetworkManager is available.
- If using `iw` or `iwlist`, scan may require sudo; script already prompts for minimal elevation.
- Install missing backend packages: `iw`, `wireless-tools`, or `network-manager`.

Problem: JSON output weird/malformed
- Install `jq` for robust JSON escaping and output.

### `scanner.sh` and `find-pi.sh`

Problem: Could not detect local IP/CIDR
- Pass explicit range:
  - `./scanner.sh --range 192.168.1.0/24`
- Ensure `iproute2` is installed and interface is up.

Problem: Very slow scans
- Reduce CIDR size.
- Tune concurrency/timeouts:
  - `--concurrency`
  - `--ping-timeout`
  - `--tcp-timeout`

Problem: `find-pi.sh` returns nothing
- Install `arp-scan` for best results.
- Fallback `nmap` mode is slower and can miss quickly-disappearing hosts.
- Ensure you are on same L2 network/VLAN.

### `kari-install.sh`

Problem: `unsupported system` / no package backend found
- Install or expose one of: `apt`, `dnf`, `pacman`, `zypper`, `rpm-ostree`, `flatpak`, `brew`.
- In restricted environments, run with `--search` first to inspect candidate sources.

Problem: Package exists but script says not found
- Use source controls:
  - `--choose`
  - `--prefer flatpak`
  - `--force-source repo|flatpak|brew`
- Search first:
  - `./kari-install.sh --search <name>`

Problem: Install fails and summary just says failed
- Check history log for details:
  - `~/.local/state/kari-install/history.log`
- Common causes: lock files, no sudo, network/DNS, stale mirrors.

### `gitprep.sh` and `push.sh`

Problem: GitHub automation fails (`gh` not authenticated)
- Run: `gh auth login`
- Validate: `gh auth status`

Problem: `push.sh` says no remote
- Add remote manually:
  - `git remote add origin git@github.com:owner/repo.git`
- Then rerun `push.sh` or plain `git push -u origin <branch>`.

Problem: Version bump/tag confusion
- `push.sh -v patch -t` is the clean path when tagging releases.
- Ensure `VERSION` file exists or allow `push.sh` to create/write it.

### `copy.sh`, `move.sh`, `rsync-backup.sh`

Problem: script exits with missing dependency
- Install `rsync`.

Problem: `move.sh` verification failed (source not deleted)
- This is intentional safety behavior.
- Re-run `copy`/`move` and inspect destination path mismatch or partial transfer conditions.

Problem: backup destination not found
- Ensure destination mountpoint exists and is mounted before running `rsync-backup.sh`.

### `refresh-ssh.sh`

Problem: still getting host key mismatch
- You may be using a different known_hosts file than expected.
- Re-run with explicit file:
  - `./refresh-ssh.sh --file ~/.ssh/known_hosts --all <host>`
- If using non-22 SSH ports, include `--all --port <port>` to remove bracketed entries.

## Final Notes

- Run scripts with `--help` first when available.
- For destructive operations, assume K.A.R.I is watching and judging your target path.
- If you are unsure which script to use, start with `verify.sh` and `--dry-run` options before anything spicy.
