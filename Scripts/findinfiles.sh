#!/usr/bin/env python3
"""
findinfiles — like finder, but searches inside files.

Examples:
  findinfiles "token"
  findinfiles --all "ssh"
  findinfiles --root /etc "PermitRootLogin"
  findinfiles --ext py,js,md "TODO"
  findinfiles --count "password"
  findinfiles --files-with-matches "apikey"
"""

from __future__ import annotations

import argparse
import os
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable, Optional

DEFAULT_SKIP_DIRS = {
    ".git",
    "node_modules",
    "__pycache__",
    ".venv",
    "venv",
    ".mypy_cache",
    ".pytest_cache",
    ".cache",
    "dist",
    "build",
}

# Some common junk/binary-ish extensions we can skip early (still also binary-check)
DEFAULT_SKIP_EXTS = {
    ".png", ".jpg", ".jpeg", ".gif", ".webp", ".bmp", ".ico",
    ".zip", ".tar", ".gz", ".bz2", ".xz", ".7z", ".rar",
    ".pdf", ".woff", ".woff2", ".ttf", ".otf",
    ".mp3", ".mp4", ".mkv", ".mov", ".avi", ".flac",
    ".exe", ".dll", ".so", ".dylib",
}

# ---------- pretty output ----------
def supports_color() -> bool:
    return sys.stdout.isatty() and os.environ.get("NO_COLOR") is None

@dataclass(frozen=True)
class C:
    enabled: bool
    reset: str = "\033[0m"
    dim: str = "\033[2m"
    bold: str = "\033[1m"
    red: str = "\033[31m"
    green: str = "\033[32m"
    yellow: str = "\033[33m"
    blue: str = "\033[34m"
    magenta: str = "\033[35m"
    cyan: str = "\033[36m"

    def wrap(self, s: str, code: str) -> str:
        if not self.enabled:
            return s
        return f"{code}{s}{self.reset}"

# ---------- core helpers ----------
def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(
        prog="findinfiles",
        description="Search for a term inside files (recursive).",
        formatter_class=argparse.RawTextHelpFormatter,
    )

    p.add_argument("term", help='Search term (wrap in quotes if it has spaces).')

    scope = p.add_mutually_exclusive_group()
    scope.add_argument("--all", action="store_true", help='Search from root "/" (like finder --all).')
    scope.add_argument("--root", type=str, help="Search from a specific root directory.")

    casing = p.add_mutually_exclusive_group()
    casing.add_argument("--ignore-case", action="store_true", help="Case-insensitive match (default).")
    casing.add_argument("--case", action="store_true", help="Case-sensitive match.")

    p.add_argument("--ext", type=str, help="Only search these extensions (comma-separated, e.g. py,js,md).")
    p.add_argument("--no-skip", action="store_true", help="Do not skip common noisy directories.")
    p.add_argument("--skip-dir", action="append", default=[], help="Extra directory name to skip (repeatable).")
    p.add_argument("--skip-ext", action="append", default=[], help="Extra extension to skip (repeatable, like .log).")

    p.add_argument("--max-size", type=int, default=5, help="Max file size (MB) to scan. Default: 5")
    p.add_argument("--context", type=int, default=0, help="Show N lines of context around matches. Default: 0")

    p.add_argument("--count", action="store_true", help="Only print total matches (and per-file if used with --files-with-matches).")
    p.add_argument("--files-with-matches", action="store_true", help="Only print file paths that contain at least one match.")
    p.add_argument("--no-color", action="store_true", help="Disable ANSI color output.")

    return p.parse_args()

def is_binary(path: Path) -> bool:
    """Heuristic binary detection: NUL byte in first 4KB."""
    try:
        with path.open("rb") as f:
            chunk = f.read(4096)
        return b"\0" in chunk
    except Exception:
        return True

def normalize_ext_list(ext_csv: Optional[str]) -> Optional[set[str]]:
    if not ext_csv:
        return None
    out: set[str] = set()
    for raw in ext_csv.split(","):
        e = raw.strip()
        if not e:
            continue
        if not e.startswith("."):
            e = "." + e
        out.add(e.lower())
    return out if out else None

def iter_files(start: Path, skip_dirs: set[str]) -> Iterable[Path]:
    # os.walk is still the simplest & fastest cross-platform option
    for root, dirs, files in os.walk(start):
        # Prune dirs in-place
        dirs[:] = [d for d in dirs if d not in skip_dirs]
        root_path = Path(root)

        for name in files:
            yield root_path / name

def highlight_match(line: str, term: str, case_sensitive: bool, color: C) -> str:
    """Highlight all occurrences of term in line (simple substring)."""
    if not color.enabled or not term:
        return line

    if case_sensitive:
        needle = term
        hay = line
        idx = 0
        out = []
        while True:
            j = hay.find(needle, idx)
            if j == -1:
                out.append(hay[idx:])
                break
            out.append(hay[idx:j])
            out.append(color.wrap(hay[j:j+len(needle)], color.yellow + color.bold))
            idx = j + len(needle)
        return "".join(out)

    # case-insensitive highlight: find on lowered, slice original
    low = line.lower()
    needle = term.lower()
    idx = 0
    out = []
    while True:
        j = low.find(needle, idx)
        if j == -1:
            out.append(line[idx:])
            break
        out.append(line[idx:j])
        out.append(color.wrap(line[j:j+len(needle)], color.yellow + color.bold))
        idx = j + len(needle)
    return "".join(out)

# ---------- main search ----------
def main() -> int:
    args = parse_args()

    start = Path(".")
    if args.all:
        start = Path("/")
    elif args.root:
        start = Path(args.root)

    # Default behavior is ignore-case (like the original)
    case_sensitive = bool(args.case)

    term = args.term if case_sensitive else args.term.lower()

    color = C(enabled=(supports_color() and not args.no_color))

    only_exts = normalize_ext_list(args.ext)

    skip_dirs = set() if args.no_skip else set(DEFAULT_SKIP_DIRS)
    skip_dirs.update(set(args.skip_dir or []))

    skip_exts = set(DEFAULT_SKIP_EXTS)
    for e in args.skip_ext or []:
        e = e.strip()
        if not e:
            continue
        if not e.startswith("."):
            e = "." + e
        skip_exts.add(e.lower())

    max_bytes = max(0, args.max_size) * 1024 * 1024

    total_matches = 0
    files_with_matches = 0

    # Header (tiny bit of flair, not cringe)
    if not args.count and not args.files_with_matches:
        scope_label = str(start)
        print(color.wrap(f"🔎 findinfiles", color.cyan + color.bold), end="")
        print(color.wrap(f"  term=", color.dim) + color.wrap(f"{args.term!r}", color.magenta + color.bold), end="")
        print(color.wrap(f"  root=", color.dim) + color.wrap(scope_label, color.blue + color.bold))
        if not args.no_skip:
            print(color.wrap(f"↳ skipping dirs: {', '.join(sorted(skip_dirs))}", color.dim))

    for path in iter_files(start, skip_dirs):
        # Extension filters
        ext = path.suffix.lower()
        if only_exts is not None and ext not in only_exts:
            continue
        if only_exts is None and ext in skip_exts:
            continue

        # Size guard
        try:
            st = path.stat()
            if max_bytes and st.st_size > max_bytes:
                continue
        except Exception:
            continue

        # Binary guard
        if is_binary(path):
            continue

        # Scan
        file_match_count = 0
        try:
            with path.open("r", encoding="utf-8", errors="ignore") as f:
                # If context requested, we need a small rolling buffer
                if args.context > 0:
                    buf: list[str] = []
                    lines = list(f)
                    n = len(lines)
                    for i, line in enumerate(lines, 1):
                        hay = line if case_sensitive else line.lower()
                        if term in hay:
                            file_match_count += 1
                            total_matches += 1

                            if args.files_with_matches:
                                # We’ll print just the file path later
                                continue

                            lo = max(0, i - 1 - args.context)
                            hi = min(n, i - 1 + args.context + 1)

                            header = f"{path}:{i}:"
                            print(color.wrap(header, color.green + color.bold), highlight_match(lines[i-1].rstrip("\n"), args.term, case_sensitive, color))

                            # context before
                            for k in range(lo, i - 1):
                                print(color.wrap(f"{path}:{k+1}:", color.dim), lines[k].rstrip("\n"))
                            # context after
                            for k in range(i, hi):
                                print(color.wrap(f"{path}:{k+1}:", color.dim), lines[k].rstrip("\n"))
                else:
                    for i, line in enumerate(f, 1):
                        hay = line if case_sensitive else line.lower()
                        if term in hay:
                            file_match_count += 1
                            total_matches += 1

                            if args.files_with_matches:
                                continue

                            prefix = f"{path}:{i}:"
                            print(color.wrap(prefix, color.green + color.bold), highlight_match(line.rstrip("\n"), args.term, case_sensitive, color))
        except Exception:
            continue

        if file_match_count > 0:
            files_with_matches += 1
            if args.files_with_matches:
                print(str(path))
            # If --count and not files-only, print per-file counts
            if args.count and not args.files_with_matches:
                print(f"{path}: {file_match_count}")

    # Final counts
    if args.count and args.files_with_matches:
        # With both, user wants file list already printed; still give totals
        pass

    if args.count or args.files_with_matches:
        # Always provide a compact summary at the end
        summary = f"matches={total_matches} files={files_with_matches}"
        print(color.wrap(summary, color.cyan + color.bold))

    return 0 if total_matches > 0 else 1


if __name__ == "__main__":
    raise SystemExit(main())

