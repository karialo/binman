#!/usr/bin/env bash
# Description: Add/commit/push with optional semver bump, tag, changelog, and GitHub release.
# App: push
# Title: Git Push (versioned)
# Version: 1.0.0
# Usage: push [-a] [-m "msg"] [-v patch|minor|major] [-t] [-r] [--dry]
#   -a            Stage all changes
#   -m "msg"      Commit message (if omitted and there are staged changes, opens $EDITOR)
#   -v TYPE       Bump VERSION file (semver): patch|minor|major (creates tag if -t given)
#   -t            Create git tag v<VERSION> after bump/commit
#   -r            Create GitHub release with changelog (requires gh)
#   --dry         Show what would happen, do nothing
#   -h            Help

set -euo pipefail
shopt -s nocasematch

APP_TITLE="Git Push (versioned)"
APP_VERSION="1.0.0"

# ── Styling ────────────────────────────────────────────────────────────────
c() { tput setaf "$1" 2>/dev/null || true; }
b() { tput bold 2>/dev/null || true; }
rs() { tput sgr0 2>/dev/null || true; }
ok() { echo "$(c 2)✓$(rs) $*"; }
warn() { echo "$(c 3)!$(rs) $*"; }
err() { echo "$(c 1)✗$(rs) $*" >&2; }

die(){ err "$@"; exit 1; }

# ── Helpers ────────────────────────────────────────────────────────────────
in_repo(){ git rev-parse --git-dir >/dev/null 2>&1; }
branch(){ git symbolic-ref --short HEAD; }
remote(){ git remote 2>/dev/null | head -n1; }
latest_tag(){ git describe --tags --abbrev=0 2>/dev/null || true; }

read_version(){
  if [[ -f VERSION ]]; then cat VERSION
  else echo ""
  fi
}
write_version(){ echo "$1" > VERSION; }

bump_semver(){
  local cur="$1" typ="$2"
  [[ -z "$cur" ]] && cur="0.0.0"
  IFS=. read -r MA MI PA <<<"$cur"
  case "$typ" in
    patch) ((PA++));;
    minor) ((MI++)); PA=0;;
    major) ((MA++)); MI=0; PA=0;;
    *) die "Unknown bump type: $typ"
  esac
  echo "${MA}.${MI}.${PA}"
}

changelog_since(){
  local since="$1"
  if [[ -n "$since" ]]; then
    git log --pretty=format:'* %s (%h)' "${since}..HEAD"
  else
    git log --pretty=format:'* %s (%h)'
  fi
}

# ── Parse args ─────────────────────────────────────────────────────────────
STAGE_ALL=0; DO_TAG=0; DO_REL=0; DRY=0
MSG=""; BUMP=""

while (( $# )); do
  case "$1" in
    -a) STAGE_ALL=1;;
    -m) shift; MSG="${1-}";;
    -v) shift; BUMP="${1-}";;
    -t) DO_TAG=1;;
    -r) DO_REL=1;;
    --dry) DRY=1;;
    -h|--help)
      sed -n '1,40p' "$0" | sed -n '1,25p' | sed 's/^# \{0,1\}//' | sed 's/^$//'
      exit 0;;
    *) die "Unknown arg: $1";;
  esac; shift
done

in_repo || die "Not inside a git repo."

# ── Preflight ──────────────────────────────────────────────────────────────
REMOTE=$(remote)
[[ -z "$REMOTE" ]] && warn "No git remote set; will create commits but not push."
BRANCH=$(branch)

if (( STAGE_ALL )); then
  (( DRY )) && ok "[dry] git add -A" || git add -A
fi

# If bump requested, adjust VERSION before commit
NEWVER=""
if [[ -n "$BUMP" ]]; then
  CURVER="$(read_version)"
  NEWVER="$(bump_semver "$CURVER" "$BUMP")"
  (( DRY )) && ok "[dry] write VERSION $NEWVER" || write_version "$NEWVER"
  (( DRY )) && ok "[dry] git add VERSION" || git add VERSION
  ok "Version bumped: ${CURVER:-<none>} → ${NEWVER}"
fi

# Commit if there are staged changes
if ! git diff --cached --quiet; then
  if [[ -z "$MSG" ]]; then
    if (( DRY )); then ok "[dry] open editor for commit message"
    else git commit
    fi
  else
    (( DRY )) && ok "[dry] git commit -m \"$MSG\"" || git commit -m "$MSG"
  fi
else
  ok "No staged changes to commit."
fi

# Tagging
if (( DO_TAG )); then
  TAG=""
  if [[ -n "$NEWVER" ]]; then TAG="v${NEWVER}"
  else
    # If no bump, use latest VERSION if exists
    V="$(read_version)"
    [[ -z "$V" ]] && die "No version available for tagging; use -v patch|minor|major or create VERSION file."
    TAG="v${V}"
  fi
  (( DRY )) && ok "[dry] git tag -a \"$TAG\" -m \"Release $TAG\"" || git tag -a "$TAG" -m "Release $TAG"
  ok "Tagged $TAG"
fi

# Push
if [[ -n "$REMOTE" ]]; then
  (( DRY )) && ok "[dry] git push $REMOTE $BRANCH" || git push "$REMOTE" "$BRANCH"
  if (( DO_TAG )); then
    (( DRY )) && ok "[dry] git push $REMOTE --tags" || git push "$REMOTE" --tags
  fi
else
  warn "Skipping push (no remote)."
fi

# Release via gh
if (( DO_REL )); then
  command -v gh >/dev/null 2>&1 || die "gh not found; install GitHub CLI for releases."
  TGT="$(latest_tag)"
  [[ -z "$TGT" ]] && die "No tag found to release. Use -t (and optionally -v) first."
  CHLOG="$(changelog_since "$(git describe --tags --abbrev=0 "${TGT}^" 2>/dev/null || echo "")")"
  (( DRY )) && ok "[dry] gh release create $TGT -t \"$TGT\" -n \"$CHLOG\"" \
            || gh release create "$TGT" -t "$TGT" -n "$CHLOG"
  ok "GitHub release created for $TGT"
fi

ok "Done. $( [[ -n "$NEWVER" ]] && echo "Version: $NEWVER" || echo "Branch: $BRANCH" )"
