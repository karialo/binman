#!/usr/bin/env bash
# gitprep.sh — initialize the CURRENT directory as a clean git repo
# Author: K.A.R.I. for Daddy
# Version: 1.0.0

set -Eeuo pipefail

VERSION="1.0.0"

# defaults
BRANCH="main"
REMOTE_URL=""
DO_PUSH=0
GH_CREATE=""
GH_VISIBILITY="public"  # or "private"

say(){ printf "%s\n" "$*"; }
ok(){ printf "\e[32m%s\e[0m\n" "$*"; }
warn(){ printf "\e[33m%s\e[0m\n" "$*"; }
err(){ printf "\e[31m%s\e[0m\n" "$*" 1>&2; }

usage(){
  cat <<USAGE
gitprep v${VERSION}
Initialize the current directory as a git repo, add README + .gitignore, make the first commit,
optionally set a remote, and (optionally) push.

USAGE:
  gitprep [--branch main] [--remote <git@...|https://...>] [--push]
          [--gh <owner/repo>] [--private|--public]

Options:
  --branch NAME        Initial branch name (default: main)
  --remote URL         Set 'origin' to URL (add or replace)
  --push               Push to origin <branch> after prepping
  --gh OWNER/REPO      Create remote with GitHub CLI (gh) and set origin
  --private            Use private visibility when creating with --gh (default: public)
  --public             Explicitly set public (default)
  -h, --help           Show this help

Examples:
  gitprep
  gitprep --remote git@github.com:you/cool-tool.git --push
  gitprep --gh you/cool-tool --private --push
  gitprep --branch trunk
USAGE
}

# parse args
while [[ $# -gt 0 ]]; do
  case "$1" in
    --branch) BRANCH="${2:-}"; shift 2 ;;
    --remote) REMOTE_URL="${2:-}"; shift 2 ;;
    --push) DO_PUSH=1; shift ;;
    --gh) GH_CREATE="${2:-}"; shift 2 ;;
    --private) GH_VISIBILITY="private"; shift ;;
    --public) GH_VISIBILITY="public"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) err "Unknown option: $1"; usage; exit 2 ;;
  esac
done

command -v git >/dev/null 2>&1 || { err "git is required"; exit 1; }

CWD_NAME="$(basename "$PWD")"

# --- init repo if needed ---
if [[ ! -d .git ]]; then
  # Prefer 'git init -b' if supported
  if git init -b "$BRANCH" >/dev/null 2>&1; then
    ok "Initialized git repo on branch '$BRANCH'"
  else
    git init >/dev/null
    # set HEAD ref to desired branch before first commit (portable trick)
    git symbolic-ref HEAD "refs/heads/$BRANCH" >/dev/null 2>&1 || true
    ok "Initialized git repo (legacy mode), target branch '$BRANCH'"
  fi
else
  warn "Already a git repo: $(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo '?')"
  # Try to rename if current branch is 'master' and desired is not
  CURB="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "$BRANCH")"
  if [[ "$CURB" = "master" && "$BRANCH" != "master" ]]; then
    git branch -M "$BRANCH" || true
    ok "Renamed branch 'master' → '$BRANCH'"
  fi
fi

# --- seed README if missing ---
if [[ ! -f README.md ]]; then
  cat > README.md <<EOF
# ${CWD_NAME}

Initialized with \`gitprep\` — ${BRANCH} branch.

## Quick start

- Edit files
- Commit changes
- (Optional) set a remote and push
EOF
  ok "Created README.md"
else
  warn "README.md exists (leaving as-is)"
fi

# --- seed .gitignore if missing ---
if [[ ! -f .gitignore ]]; then
  cat > .gitignore <<'EOF'
# OS / editors
.DS_Store
Thumbs.db
.idea/
.vscode/
*.swp

# Python
__pycache__/
*.py[cod]
*.pyo
.env
.venv/
venv/
dist/
build/

# Node
node_modules/
npm-debug.log*
yarn-error.log*

# Logs
*.log

# Misc
*.tmp
EOF
  ok "Created .gitignore"
else
  warn ".gitignore exists (leaving as-is)"
fi

# --- stage & commit ---
git add -A
# Determine if first commit
if git rev-parse --verify HEAD >/dev/null 2>&1; then
  # Not the first commit; make a snapshot commit only if there are staged changes
  if ! git diff --cached --quiet; then
    git commit -m "chore: snapshot $(date -Iseconds)" >/dev/null
    ok "Committed snapshot"
  else
    warn "No changes to commit"
  fi
else
  git commit -m "init: ${CWD_NAME} (gitprep v${VERSION})" >/dev/null
  ok "Created initial commit"
fi

# --- configure remote origin (URL or gh create) ---
if [[ -n "$GH_CREATE" ]]; then
  if command -v gh >/dev/null 2>&1; then
    VISFLAG="--public"; [[ "$GH_VISIBILITY" = "private" ]] && VISFLAG="--private"
    # Non-interactive create from current directory as source
    gh repo create "$GH_CREATE" "$VISFLAG" --source . --push >/dev/null 2>&1 || {
      err "Failed to create GitHub repo via gh (check auth?)."
      exit 1
    }
    ok "Created GitHub repo: $GH_CREATE (and pushed)"
    exit 0
  else
    err "'gh' CLI not found; install GitHub CLI or use --remote"
    exit 1
  fi
fi

if [[ -n "$REMOTE_URL" ]]; then
  if git remote get-url origin >/dev/null 2>&1; then
    git remote set-url origin "$REMOTE_URL"
    ok "Updated origin → $REMOTE_URL"
  else
    git remote add origin "$REMOTE_URL"
    ok "Added origin → $REMOTE_URL"
  fi
fi

# --- push (optional) ---
if [[ $DO_PUSH -eq 1 ]]; then
  if git remote get-url origin >/dev/null 2>&1; then
    git push -u origin "$BRANCH"
    ok "Pushed to origin/$BRANCH"
  else
    err "No remote 'origin' set. Use --remote <URL> or --gh <owner/repo>."
    exit 1
  fi
else
  say ""
  say "Next steps:"
  if git remote get-url origin >/dev/null 2>&1; then
    say "  • Push now: git push -u origin ${BRANCH}"
  else
    say "  • Set remote: git remote add origin <git@... or https://...>"
    say "  • Then push: git push -u origin ${BRANCH}"
    say "  • Or rerun: gitprep --remote <URL> --push"
  fi
fi
