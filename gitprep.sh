#!/usr/bin/env bash
# gitprep.sh — initialize the CURRENT directory as a clean git repo
# Author: K.A.R.I. for Daddy
# Version: 1.1.0

set -Eeuo pipefail

VERSION="1.1.0"

# defaults
BRANCH="main"
REMOTE_URL=""
DO_PUSH=0
GH_CREATE=""
GH_VISIBILITY="public"  # or "private"

# new: smart auto-remote/create
AUTO=0
OWNER=""
PROTO="ssh"             # ssh | https

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
          [--auto] [--owner <github-username>] [--proto ssh|https]

Options:
  --branch NAME        Initial branch name (default: main)
  --remote URL         Set 'origin' to URL (add or replace)
  --push               Push to origin <branch> after prepping
  --gh OWNER/REPO      Create remote with GitHub CLI (gh) and set origin
  --private            Use private visibility when creating with --gh (default: public)
  --public             Explicitly set public (default)
  --auto               If gh is available, auto-detect owner/<cwd>, set origin if exists,
                       otherwise create it on GitHub (respects --private/--public)
  --owner NAME         Override detected GitHub owner/login used by --auto
  --proto ssh|https    Remote URL protocol for --auto (default: ssh)
  -h, --help           Show this help

Examples:
  gitprep
  gitprep --remote git@github.com:you/cool-tool.git --push
  gitprep --gh you/cool-tool --private --push
  gitprep --auto --push            # smart: set or create origin for <owner>/<cwd>
  gitprep --auto --owner karialo --proto https --private --push
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
    --auto) AUTO=1; shift ;;
    --owner) OWNER="${2:-}"; shift 2 ;;
    --proto) PROTO="${2:-ssh}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) err "Unknown option: $1"; usage; exit 2 ;;
  esac
done

command -v git >/dev/null 2>&1 || { err "git is required"; exit 1; }

CWD_NAME="$(basename "$PWD")"

# --- init repo if needed ---
if [[ ! -d .git ]]; then
  if git init -b "$BRANCH" >/dev/null 2>&1; then
    ok "Initialized git repo on branch '$BRANCH'"
  else
    git init >/dev/null
    git symbolic-ref HEAD "refs/heads/$BRANCH" >/dev/null 2>&1 || true
    ok "Initialized git repo (legacy mode), target branch '$BRANCH'"
  fi
else
  warn "Already a git repo: $(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo '?')"
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
if git rev-parse --verify HEAD >/dev/null 2>&1; then
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

# --- helper: set origin URL ---
set_origin() {
  local url="$1"
  if git remote get-url origin >/dev/null 2>&1; then
    git remote set-url origin "$url"
    ok "Updated origin → $url"
  else
    git remote add origin "$url"
    ok "Added origin → $url"
  fi
}

# --- configure remote origin (URL or gh create or auto) ---
if [[ -n "$GH_CREATE" ]]; then
  if command -v gh >/dev/null 2>&1; then
    VISFLAG="--public"; [[ "$GH_VISIBILITY" = "private" ]] && VISFLAG="--private"
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

if [[ $AUTO -eq 1 && -z "$REMOTE_URL" ]]; then
  if command -v gh >/dev/null 2>&1; then
    # Detect owner/login when not provided
    if [[ -z "$OWNER" ]]; then
      OWNER="$(gh api user -q .login 2>/dev/null || true)"
    fi
    if [[ -z "$OWNER" ]]; then
      warn "Could not determine GitHub owner (gh auth?). Falling back to manual."
    else
      REPO_SLUG="${OWNER}/${CWD_NAME}"
      # Does the repo already exist?
      if gh repo view "$REPO_SLUG" >/dev/null 2>&1; then
        # Set origin based on protocol preference
        if [[ "$PROTO" == "https" ]]; then
          REMOTE_URL="https://github.com/${REPO_SLUG}.git"
        else
          REMOTE_URL="git@github.com:${REPO_SLUG}.git"
        fi
        ok "Found existing repo ${REPO_SLUG}"
      else
        # Create the repo
        VISFLAG="--public"; [[ "$GH_VISIBILITY" = "private" ]] && VISFLAG="--private"
        if [[ $DO_PUSH -eq 1 ]]; then
          gh repo create "$REPO_SLUG" $VISFLAG --source . --push >/dev/null 2>&1 || {
            err "Failed to create GitHub repo via gh (check auth?)."
            exit 1
          }
          ok "Created GitHub repo: ${REPO_SLUG} (and pushed)"
          exit 0
        else
          gh repo create "$REPO_SLUG" $VISFLAG --source . >/dev/null 2>&1 || {
            err "Failed to create GitHub repo via gh (check auth?)."
            exit 1
          }
          ok "Created GitHub repo: ${REPO_SLUG}"
          # set origin URL now so next steps show the push hint
          if [[ "$PROTO" == "https" ]]; then
            REMOTE_URL="https://github.com/${REPO_SLUG}.git"
          else
            REMOTE_URL="git@github.com:${REPO_SLUG}.git"
          fi
        fi
      fi
    fi
  else
    warn "--auto requested but 'gh' CLI not found; skipping auto."
  fi
fi

if [[ -n "$REMOTE_URL" ]]; then
  set_origin "$REMOTE_URL"
fi

# --- push (optional) ---
if [[ $DO_PUSH -eq 1 ]]; then
  if git remote get-url origin >/dev/null 2>&1; then
    git push -u origin "$BRANCH"
    ok "Pushed to origin/$BRANCH"
  else
    err "No remote 'origin' set. Use --remote <URL> or --gh <owner/repo> or --auto."
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
    say "  • Or rerun: gitprep --auto --push   # uses gh to set/create origin"
  fi
fi
