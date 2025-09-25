#!/usr/bin/env bash
# gitprep — initialize the CURRENT directory as a clean git repo and auto-create GitHub remote
# Author: K.A.R.I. for Daddy
# Version: 1.2.0

set -Eeuo pipefail

VERSION="1.2.0"

# ---- defaults ---------------------------------------------------------------
BRANCH="main"
VISIBILITY="private"       # default safer; override with --public
PROTO="ssh"                # ssh | https for origin URL
PUSH=1                     # push by default
USE_GH=1                   # always use gh to auto-create/verify
OWNER=""                   # auto-detect from gh auth
NAME=""                    # defaults to basename of CWD

say(){ printf "%s\n" "$*"; }
ok(){ printf "\e[32m%s\e[0m\n" "$*"; }
warn(){ printf "\e[33m%s\e[0m\n" "$*"; }
err(){ printf "\e[31m%s\e[0m\n" "$*" 1>&2; exit 1; }
exists(){ command -v "$1" >/dev/null 2>&1; }

usage(){
  cat <<USAGE
gitprep v${VERSION}
Initialize current directory as a git repo, seed README/.gitignore, commit, and
**automatically create or wire a GitHub repo** with origin set and pushed.

USAGE:
  gitprep [options]

Options:
  --branch NAME        Initial branch (default: main)
  --public             Make the GitHub repo public (default: private)
  --private            Make the GitHub repo private
  --proto ssh|https    Origin protocol (default: ssh)
  --owner NAME         GitHub owner/org (default: your gh login)
  --name  NAME         Repository name (default: basename of CWD)
  --no-push            Prepare + create repo, but don't push
  --no-gh              Don't touch GitHub (local repo only)
  -h, --help           Show this help

Examples:
  gitprep
  gitprep --public
  gitprep --owner karialo --name TestTool --proto https
  gitprep --no-push      # create remote and set origin, skip first push
  gitprep --no-gh        # local-only init (no remote)
USAGE
}

# ---- args -------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --branch) BRANCH="${2:-}"; shift 2 ;;
    --public) VISIBILITY="public"; shift ;;
    --private) VISIBILITY="private"; shift ;;
    --proto) PROTO="${2:-ssh}"; shift 2 ;;
    --owner) OWNER="${2:-}"; shift 2 ;;
    --name)  NAME="${2:-}"; shift 2 ;;
    --no-push) PUSH=0; shift ;;
    --no-gh) USE_GH=0; shift ;;
    -h|--help) usage; exit 0 ;;
    *) err "Unknown option: $1" ;;
  esac
done

# ---- prereqs ----------------------------------------------------------------
exists git || err "git is required"
if [[ $USE_GH -eq 1 ]]; then
  exists gh || err "'gh' CLI not found. Install GitHub CLI or run with --no-gh."
  gh auth status >/dev/null 2>&1 || err "'gh' not authenticated. Run: gh auth login --web --ssh"
fi

# ---- repo name/owner --------------------------------------------------------
CWD_NAME="$(basename "$PWD")"
REPO_NAME="${NAME:-$CWD_NAME}"

if [[ $USE_GH -eq 1 && -z "$OWNER" ]]; then
  OWNER="$(gh api user --jq .login 2>/dev/null || true)"
  [[ -z "$OWNER" ]] && err "Could not determine GitHub owner. Use --owner NAME."
fi

# ---- init repo / branch -----------------------------------------------------
if [[ ! -d .git ]]; then
  if git init -b "$BRANCH" >/dev/null 2>&1; then
    ok "Initialized git repo on branch '$BRANCH'"
  else
    git init >/dev/null
    git symbolic-ref HEAD "refs/heads/$BRANCH" >/dev/null 2>&1 || true
    ok "Initialized git repo (legacy mode), target branch '$BRANCH'"
  fi
else
  CURB="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "$BRANCH")"
  if [[ "$CURB" != "$BRANCH" ]]; then
    # create/switch without nuking history
    if git show-ref --verify --quiet "refs/heads/$BRANCH"; then
      git checkout "$BRANCH" >/dev/null 2>&1 || true
    else
      git checkout -b "$BRANCH" >/dev/null 2>&1 || true
    fi
  fi
  ok "Repo present (branch: $(git rev-parse --abbrev-ref HEAD))"
fi

# ---- seed files -------------------------------------------------------------
if [[ ! -f README.md ]]; then
  cat > README.md <<EOF
# ${REPO_NAME}

Initialized with \`gitprep\` — branch \`${BRANCH}\`.
EOF
  ok "Created README.md"
else
  warn "README.md exists (leaving as-is)"
fi

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

# ---- commit snapshot / initial ---------------------------------------------
git add -A
if git rev-parse --verify HEAD >/dev/null 2>&1; then
  if ! git diff --cached --quiet; then
    git commit -m "chore: snapshot ($(date -Iseconds))" >/dev/null
    ok "Committed snapshot"
  else
    warn "No changes to commit"
  fi
else
  git commit -m "init: ${REPO_NAME} (gitprep v${VERSION})" >/dev/null
  ok "Created initial commit"
fi

# ---- helpers ----------------------------------------------------------------
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

canonical_ssh_url() {
  gh repo view "$1" --json sshUrl -q .sshUrl 2>/dev/null || true
}
canonical_https_url() {
  gh repo view "$1" --json url -q .url 2>/dev/null || true
}

# ---- remote creation / wiring ----------------------------------------------
if [[ $USE_GH -eq 1 ]]; then
  SLUG="${OWNER}/${REPO_NAME}"
  # Does it already exist?
  if gh repo view "$SLUG" >/dev/null 2>&1; then
    ok "Found existing GitHub repo: $SLUG"
    if [[ "$PROTO" == "https" ]]; then
      URL="$(canonical_https_url "$SLUG")"; [[ -n "$URL" ]] || URL="https://github.com/${SLUG}.git"
    else
      URL="$(canonical_ssh_url "$SLUG")"; [[ -n "$URL" ]] || URL="git@github.com:${SLUG}.git"
    fi
    set_origin "$URL"
  else
    ok "Creating GitHub repo: $SLUG (${VISIBILITY})"
    # Use current branch; set origin and push in one go
    if gh repo create "$SLUG" --"$VISIBILITY" --source . --remote origin ${PUSH:+--push} -y >/dev/null 2>&1; then
      # Ensure origin is the canonical URL format we want
      if [[ "$PROTO" == "https" ]]; then
        URL="$(canonical_https_url "$SLUG")"; [[ -n "$URL" ]] || URL="https://github.com/${SLUG}.git"
      else
        URL="$(canonical_ssh_url "$SLUG")"; [[ -n "$URL" ]] || URL="git@github.com:${SLUG}.git"
      fi
      set_origin "$URL"
      ok "GitHub repo created${PUSH:+ and pushed} → $SLUG"
    else
      err "Failed to create GitHub repo via gh. Check auth/permissions or if the name is taken."
    fi
  fi
else
  warn "--no-gh set: skipping remote creation."
fi

# ---- push (if not pushed already) ------------------------------------------
if [[ $PUSH -eq 1 ]]; then
  if git remote get-url origin >/dev/null 2>&1; then
    # If gh already pushed, this will be a no-op fast-forward
    git push -u origin "$BRANCH" >/dev/null 2>&1 || err "Push failed. Check SSH/HTTPS auth."
    ok "Pushed $BRANCH → origin"
  else
    warn "No origin set; skipping push."
  fi
else
  say ""
  say "Next steps:"
  if git remote get-url origin >/dev/null 2>&1; then
    say "  • Push now: git push -u origin ${BRANCH}"
  else
    say "  • Set remote: git remote add origin git@github.com:${OWNER:-<owner>}/${REPO_NAME}.git"
    say "  • Then push:  git push -u origin ${BRANCH}"
  fi
fi
