#!/usr/bin/env bash
# Description: Cross-distro package installer wrapper (apt/dnf/pacman/zypper/rpm-ostree)
VERSION="0.1.0"
set -Eeuo pipefail

APP="$(basename "$0")"

say() { printf '%s\n' "$*"; }
err() { printf '%s\n' "$*" >&2; }

usage() {
  cat <<EOF
Usage:
  ${APP} [options] <package> [more packages...]

Options:
  -s, --search        Search for a package name (best effort)
  -n, --dry-run       Show what would run, don’t run it
  -y, --yes           Assume yes where supported (apt/dnf/zypper)
  --fail-fast         Stop on first failure
  --continue-on-error Keep going after errors (default)
  --prefer SOURCE     Prefer: auto|repo|flatpak|brew (default: auto)
  --force-source SRC  Force: repo|flatpak|brew
  --choose            Prompt when multiple sources match (TTY only)
  --limit N           Limit search output per source (default: 25)
  --full              Show raw search output (no curation)
  -h, --help          Show help
  --version           Show version

Examples:
  ${APP} ripgrep fd
  ${APP} --search neovim
  ${APP} -n go git
  ${APP} --prefer flatpak gimp
  ${APP} --dry-run --choose steam
EOF
}

SEARCH=0
DRYRUN=0
YES=0
FULL=0
LIMIT=25
FAIL_FAST=0
CONTINUE_ON_ERROR=1
PREFER="auto"
FORCE_SOURCE=""
CHOOSE=0
PKGS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    -s|--search) SEARCH=1; shift ;;
    -n|--dry-run) DRYRUN=1; shift ;;
    -y|--yes) YES=1; shift ;;
    --fail-fast) FAIL_FAST=1; CONTINUE_ON_ERROR=0; shift ;;
    --continue-on-error) CONTINUE_ON_ERROR=1; FAIL_FAST=0; shift ;;
    --prefer)
      PREFER="${2:-}"; shift 2
      case "$PREFER" in
        auto|repo|flatpak|brew) ;;
        *) err "$APP: invalid --prefer (use auto|repo|flatpak|brew)"; exit 2 ;;
      esac
      ;;
    --force-source)
      FORCE_SOURCE="${2:-}"; shift 2
      case "$FORCE_SOURCE" in
        repo|flatpak|brew) ;;
        *) err "$APP: invalid --force-source (use repo|flatpak|brew)"; exit 2 ;;
      esac
      ;;
    --choose) CHOOSE=1; shift ;;
    --limit)
      LIMIT="${2:-}"; shift 2
      [[ "$LIMIT" =~ ^[0-9]+$ ]] || { err "$APP: invalid --limit (use a number)"; exit 2; }
      ;;
    --full|--raw) FULL=1; shift ;;
    -h|--help) usage; exit 0 ;;
    --version) say "$APP v$VERSION"; exit 0 ;;
    --) shift; break ;;
    -*) err "$APP: unknown option: $1"; err "Try: $APP --help"; exit 2 ;;
    *) PKGS+=("$1"); shift ;;
  esac
done
if [[ $# -gt 0 ]]; then PKGS+=("$@"); fi

if [[ ${#PKGS[@]} -lt 1 ]]; then
  usage
  exit 2
fi

# Detect distro-ish info
ID=""
ID_LIKE=""
if [[ -r /etc/os-release ]]; then
  # shellcheck disable=SC1091
  . /etc/os-release
  ID="${ID:-}"
  ID_LIKE="${ID_LIKE:-}"
fi

have() { command -v "$1" >/dev/null 2>&1; }

run() {
  if [[ "$DRYRUN" -eq 1 ]]; then
    say "[dry-run] $*"
  else
    eval "$@"
  fi
}

iso_now() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }

cmd_str() { printf '%q ' "$@"; }

run_cmd() {
  if [[ "$DRYRUN" -eq 1 ]]; then
    say "[dry-run] $(cmd_str "$@")"
    return 0
  fi
  set +e
  "$@"
  local rc=$?
  set -e
  return $rc
}

run_capture() {
  RUN_OUT=""
  RUN_RC=0
  if [[ "$DRYRUN" -eq 1 ]]; then
    say "[dry-run] $(cmd_str "$@")"
    return 0
  fi
  set +e
  RUN_OUT="$("$@" 2>&1)"
  RUN_RC=$?
  set -e
  return $RUN_RC
}

print_curated_results() {
  local q="$1" source="$2" input="$3"
  local limit="$LIMIT"
  [[ "$limit" -gt 0 ]] || limit=25
  if [[ -z "$input" ]]; then
    say "(no matches)"
    return 0
  fi
  case "$source" in
    repo)
      local total strong_shown weak_shown remaining
      total="$(printf "%s\n" "$input" | awk -v q="$q" '
        BEGIN{IGNORECASE=1}
        {
          name=$1; line=$0
          if (index(tolower(line), tolower(q))>0) {
            if (index(tolower(name), tolower(q))>0) s++
            else w++
          }
        }
        END{print s+w+0}' | tr -d ' ')"
      strong_shown="$(printf "%s\n" "$input" | awk -v q="$q" -v lim="$limit" '
        BEGIN{IGNORECASE=1}
        {
          name=$1; line=$0
          l_name=tolower(name); l_q=tolower(q)
          if (index(l_name, l_q)>0) {
            score=2
            if (l_name==l_q) score=0
            else if (index(l_name, l_q)==1) score=1
            len=length(name)
            print score "\t" len "\t" l_name "\t" line
          }
        }' | sort -n -k1,1 -k2,2 -k3,3 | head -n "$limit" | wc -l | tr -d ' ')"
      if [[ "$strong_shown" -eq 0 ]]; then
        strong_shown=0
      fi
      if (( strong_shown > 0 )); then
        printf "%s\n" "$input" | awk -v q="$q" '
          BEGIN{IGNORECASE=1}
          {
            name=$1; line=$0
            l_name=tolower(name); l_q=tolower(q)
            if (index(l_name, l_q)>0) {
              score=2
              if (l_name==l_q) score=0
              else if (index(l_name, l_q)==1) score=1
              len=length(name)
              print score "\t" len "\t" l_name "\t" line
            }
          }' | sort -n -k1,1 -k2,2 -k3,3 | cut -f4- | head -n "$limit"
      fi
      remaining=$((limit - strong_shown))
      weak_shown=0
      if (( remaining > 0 )); then
        weak_shown="$(printf "%s\n" "$input" | awk -v q="$q" -v lim="$remaining" '
          BEGIN{IGNORECASE=1}
          {
            name=$1; line=$0
            if (index(tolower(line), tolower(q))>0 && index(tolower(name), tolower(q))==0) print line
          }' | head -n "$remaining" | wc -l | tr -d ' ')"
        if (( weak_shown > 0 )); then
          say "Weak matches:"
          printf "%s\n" "$input" | awk -v q="$q" '
            BEGIN{IGNORECASE=1}
            {
              name=$1; line=$0
              if (index(tolower(line), tolower(q))>0 && index(tolower(name), tolower(q))==0) print line
            }' | head -n "$remaining"
        fi
      fi
      if (( strong_shown + weak_shown == 0 )); then
        say "(no matches)"
        return 0
      fi
      if (( total > strong_shown + weak_shown )); then
        say "(+ $((total - strong_shown - weak_shown)) more; rerun with --full or --limit $((limit * 2)))"
      fi
      ;;
    brew)
      local total shown have_strong
      have_strong="$(printf "%s\n" "$input" | awk -v q="$q" '
        BEGIN{IGNORECASE=1}
        {
          line=$0
          l=tolower(line); ql=tolower(q)
          if (l==ql || line ~ ("(^|[^[:alnum:]])" q "([^[:alnum:]]|$)") || index(l, ql)==1) { print line; exit 0 }
        }' | wc -l | tr -d ' ')"
      total="$(printf "%s\n" "$input" | awk -v q="$q" -v strong="$have_strong" '
        BEGIN{IGNORECASE=1}
        {
          line=$0
          l=tolower(line); ql=tolower(q)
          exact=(l==ql)
          token=(line ~ ("(^|[^[:alnum:]])" q "([^[:alnum:]]|$)"))
          prefix=(index(l, ql)==1)
          has_sub=(index(l, ql)>0)
          if (exact || token || prefix || (!strong && has_sub)) c++
        }
        END{print c+0}' | tr -d ' ')"
      shown="$(printf "%s\n" "$input" | awk -v q="$q" -v lim="$limit" -v strong="$have_strong" '
        BEGIN{IGNORECASE=1}
        {
          line=$0
          l=tolower(line); ql=tolower(q)
          score=0
          if (l==ql) score=100
          else if (line ~ ("(^|[^[:alnum:]])" q "([^[:alnum:]]|$)")) score=90
          else if (index(l, ql)==1) score=80
          else if (!strong && index(l, ql)>0) score=50
          if (score>0) print score "\t" line
        }' | sort -rn | cut -f2- | head -n "$limit" | wc -l | tr -d ' ')"
      if [[ "$shown" -eq 0 ]]; then
        say "(no matches)"
        return 0
      fi
      printf "%s\n" "$input" | awk -v q="$q" -v lim="$limit" -v strong="$have_strong" '
        BEGIN{IGNORECASE=1}
        {
          line=$0
          l=tolower(line); ql=tolower(q)
          score=0
          if (l==ql) score=100
          else if (line ~ ("(^|[^[:alnum:]])" q "([^[:alnum:]]|$)")) score=90
          else if (index(l, ql)==1) score=80
          else if (!strong && index(l, ql)>0) score=50
          if (score>0) print score "\t" line
        }' | sort -rn | cut -f2- | head -n "$limit"
      if (( total > shown )); then
        say "(+ $((total - shown)) more; rerun with --full or --limit $((limit * 2)))"
      fi
      ;;
    flatpak)
      local total shown
      total="$(printf "%s\n" "$input" | wc -l | tr -d ' ')"
      shown="$(printf "%s\n" "$input" | awk -F'\t' -v q="$q" -v lim="$limit" '
        BEGIN{IGNORECASE=1}
        {
          appid=$1; name=$2
          if (appid=="" || name=="") next
          l_app=tolower(appid); l_name=tolower(name)
          tail=l_app; sub(/^.*\./,"",tail)
          score=0
          if (l_name==tolower(q)) score=100
          else if (tail==tolower(q)) score=95
          else if (l_app ~ ("\\." tolower(q) "$")) score=90
          else if (l_name ~ ("(^|[^[:alnum:]])" q "([^[:alnum:]]|$)")) score=70
          else if (l_name ~ tolower(q) || l_app ~ tolower(q)) score=40
          if (score>=70) print score "\t" name "\t" appid
        }' | sort -rn | head -n "$limit" | wc -l | tr -d ' ')"
      if [[ "$shown" -eq 0 ]]; then
        say "(no matches)"
        return 0
      fi
      printf "%s\n" "$input" | awk -F'\t' -v q="$q" -v lim="$limit" '
        BEGIN{IGNORECASE=1}
        {
          appid=$1; name=$2
          if (appid=="" || name=="") next
          l_app=tolower(appid); l_name=tolower(name)
          tail=l_app; sub(/^.*\./,"",tail)
          score=0
          if (l_name==tolower(q)) score=100
          else if (tail==tolower(q)) score=95
          else if (l_app ~ ("\\." tolower(q) "$")) score=90
          else if (l_name ~ ("(^|[^[:alnum:]])" q "([^[:alnum:]]|$)")) score=70
          else if (l_name ~ tolower(q) || l_app ~ tolower(q)) score=40
          if (score>=70) print score "\t" name "\t" appid
        }' | sort -rn | head -n "$limit" | awk -F'\t' '{printf "%s — %s\n",$2,$3}'
      if (( total > limit )); then
        say "(+ $((total - limit)) more; rerun with --full or --limit $((limit * 2)))"
      fi
      ;;
    *)
      printf "%s\n" "$input" | head -n "$limit"
      ;;
  esac
}

recap_collect_repo() {
  local q="$1" strong_file="$2" weak_file="$3"
  [[ "$TOOL" != "unknown" ]] || return 0
  case "$TOOL" in
    rpm-ostree)
      have rpm || return 0
      run_capture bash -c 'rpm -qa | grep -i -- "$1"' _ "$q"
      ;;
    apt)
      if have apt-cache; then
        run_capture apt-cache search -- "$q"
      else
        run_capture apt search -- "$q"
      fi
      ;;
    dnf) run_capture dnf search -- "$q" ;;
    pacman) run_capture pacman -Ss -- "$q" ;;
    zypper) run_capture zypper search -- "$q" ;;
    *) return 0 ;;
  esac
  [[ -n "$RUN_OUT" ]] || return 0
  printf "%s\n" "$RUN_OUT" | awk -v q="$q" -v strong="$strong_file" -v weak="$weak_file" '
    BEGIN{IGNORECASE=1}
    {
      pkg=$1; line=$0
      if (pkg=="") next
      l_pkg=tolower(pkg); l_q=tolower(q)
      if (index(tolower(line), tolower(q))==0) next
      if (index(l_pkg, l_q)>0) {
        score=3
        if (l_pkg==l_q) score=0
        else if (index(l_pkg, l_q)==1) score=1
        else if (l_pkg ~ ("(^|[^[:alnum:]])" l_q "([^[:alnum:]]|$)")) score=2
        printf "%d\t0\trepo\t%s\n", score, pkg >> strong
      } else {
        printf "3\t0\trepo\t%s\n", pkg >> weak
      }
    }'
}

recap_collect_flatpak() {
  local q="$1" strong_file="$2"
  (( HAVE_FLATPAK )) || return 0
  run_capture flatpak search --columns=application,name -- "$q"
  [[ -n "$RUN_OUT" ]] || return 0
  printf "%s\n" "$RUN_OUT" | awk -F'\t' -v q="$q" -v strong="$strong_file" '
    BEGIN{IGNORECASE=1}
    {
      appid=$1; name=$2
      if (appid=="" || name=="") next
      l_app=tolower(appid); l_name=tolower(name); l_q=tolower(q)
      tail=l_app; sub(/^.*\./,"",tail)
      score=3
      if (l_name==l_q || tail==l_q) score=0
      else if (index(tail, l_q)==1 || index(l_name, l_q)==1) score=1
      else if (l_name ~ ("(^|[^[:alnum:]])" l_q "([^[:alnum:]]|$)") || l_app ~ ("(^|[^[:alnum:]])" l_q "([^[:alnum:]]|$)")) score=2
      else if (index(l_name, l_q)>0 || index(l_app, l_q)>0) score=3
      else next
      printf "%d\t1\tflatpak\t%s\n", score, appid >> strong
    }'
}

recap_collect_brew() {
  local q="$1" strong_file="$2"
  (( HAVE_BREW )) || return 0
  run_capture brew search -- "$q"
  if (( RUN_RC != 0 )); then
    is_brew_no_matches "$RUN_OUT" && return 0
    return 0
  fi
  [[ -n "$RUN_OUT" ]] || return 0
  printf "%s\n" "$RUN_OUT" | awk -v q="$q" -v strong="$strong_file" '
    BEGIN{IGNORECASE=1}
    {
      line=$0
      if (line=="") next
      l=tolower(line); l_q=tolower(q)
      if (index(l, l_q)==0) next
      score=3
      if (l==l_q) score=0
      else if (index(l, l_q)==1) score=1
      else if (line ~ ("(^|[^[:alnum:]])" q "([^[:alnum:]]|$)")) score=2
      else if (index(l, l_q)>0) score=3
      else next
      printf "%d\t2\tbrew\t%s\n", score, line >> strong
    }'
}

recap_print() {
  local i term strong_file weak_file
  say "Recap (Top 5 per term):"
  for i in "${!recap_terms[@]}"; do
    term="${recap_terms[$i]}"
    strong_file="${recap_strong_files[$i]}"
    weak_file="${recap_weak_files[$i]}"
    if [[ ! -s "$strong_file" && ! -s "$weak_file" ]]; then
      say "- ${term}: (none)"
      continue
    fi
    say "- ${term}:"
    local n=1
    while IFS=$'\t' read -r score bias source item; do
      say "  ${n}) [${source}] ${item}"
      n=$((n+1))
      (( n <= 5 )) || break
    done < <(sort -n -k1,1 -k2,2 -k4,4 "$strong_file")
    if (( n <= 5 )) && [[ -s "$weak_file" ]]; then
      while IFS=$'\t' read -r score bias source item; do
        say "  ${n}) [${source}] ${item}"
        n=$((n+1))
        (( n <= 5 )) || break
      done < <(sort -n -k1,1 -k2,2 -k4,4 "$weak_file")
    fi
  done
}

log_event() {
  local ts="$1" tool="$2" pkg="$3" source="$4" action="$5" status="$6" reason="$7"
  local line
  line="$(printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$ts" "$tool" "$pkg" "$source" "$action" "$status" "$reason")"
  printf '%s' "$line" >> "$LOG_FILE"
}

classify_pkg() {
  local p="${1,,}"
  case "$p" in
    vim|neovim|nvim|tmux|zsh|bash|fish|rg|ripgrep|fd|fzf|htop|curl|wget|git|jq|yq) echo "CLI" ;;
    gcc|g++|clang|make|cmake|go|golang|rust|cargo|python|python3|node|npm|pip|pipx|docker|podman) echo "DEV" ;;
    gimp*|steam*|firefox*|chromium*|chrome*|vlc|discord*|slack*|spotify*|obs*|inkscape*|krita*) echo "GUI" ;;
    kernel*|grub*|systemd*|firmware*|nvidia*|mesa*|pipewire*|pulseaudio*) echo "SYSTEM_RISK" ;;
    *) echo "UNKNOWN" ;;
  esac
}

failure_hint() {
  local out="${1,,}"
  if [[ "$out" == *"permission denied"* || "$out" == *"are you root"* || "$out" == *"sudo"* ]]; then
    echo "permission/sudo needed"
  elif [[ "$out" == *"could not resolve"* || "$out" == *"temporary failure"* || "$out" == *"network"* || "$out" == *"connection"* ]]; then
    echo "network issue"
  elif [[ "$out" == *"could not get lock"* || "$out" == *"lock"* ]]; then
    echo "lock file in use"
  else
    echo "unknown error"
  fi
}

is_atomic() {
  # rpm-ostree presence is the true tell
  have rpm-ostree
}

pkgtool() {
  # Prefer rpm-ostree if available (Atomic / Bazzite etc)
  if is_atomic; then echo "rpm-ostree"; return 0; fi
  if have apt-get; then echo "apt"; return 0; fi
  if have dnf; then echo "dnf"; return 0; fi
  if have pacman; then echo "pacman"; return 0; fi
  if have zypper; then echo "zypper"; return 0; fi
  echo "unknown"
}

TOOL="$(pkgtool)"
HAVE_FLATPAK=0; have flatpak && HAVE_FLATPAK=1
HAVE_BREW=0; have brew && HAVE_BREW=1

LOG_DIR="${HOME}/.local/state/kari-install"
LOG_FILE="${LOG_DIR}/history.log"
mkdir -p "$LOG_DIR" 2>/dev/null || true

APT_UPDATED=0

# Best-effort “search”
search_repo() {
  local q="$1"
  case "$TOOL" in
    rpm-ostree)
      if have rpm; then
        say "→ repo: rpm-ostree search (best effort)"
        if [[ "$DRYRUN" -eq 1 ]]; then
          say "[dry-run] rpm -qa | grep -i -- $(printf '%q' "$q")"
        else
          rpm -qa | grep -i -- "$q" || true
        fi
      else
        err "$APP: no good repo search method available here."
      fi
      ;;
    apt)
      if have apt-cache; then
        say "→ repo: apt-cache search"
        if (( FULL )); then
          run_cmd apt-cache search -- "$q"
        else
          run_capture apt-cache search -- "$q"
          print_curated_results "$q" "repo" "$RUN_OUT"
        fi
      else
        say "→ repo: apt search"
        if (( FULL )); then
          run_cmd apt search -- "$q"
        else
          run_capture apt search -- "$q"
          print_curated_results "$q" "repo" "$RUN_OUT"
        fi
      fi
      ;;
    dnf)
      say "→ repo: dnf search"
      if (( FULL )); then
        run_cmd dnf search -- "$q"
      else
        run_capture dnf search -- "$q"
        print_curated_results "$q" "repo" "$RUN_OUT"
      fi
      ;;
    pacman)
      say "→ repo: pacman -Ss"
      if (( FULL )); then
        run_cmd pacman -Ss -- "$q"
      else
        run_capture pacman -Ss -- "$q"
        print_curated_results "$q" "repo" "$RUN_OUT"
      fi
      ;;
    zypper)
      say "→ repo: zypper search"
      if (( FULL )); then
        run_cmd zypper search -- "$q"
      else
        run_capture zypper search -- "$q"
        print_curated_results "$q" "repo" "$RUN_OUT"
      fi
      ;;
    *)
      ;;
  esac
}

search_flatpak() {
  local q="$1"
  (( HAVE_FLATPAK )) || return 0
  say "→ flatpak: search"
  if (( FULL )); then
    run_cmd flatpak search -- "$q"
  else
    run_capture flatpak search --columns=application,name -- "$q"
    print_curated_results "$q" "flatpak" "$RUN_OUT"
  fi
}

is_brew_no_matches() {
  local out="${1,,}"
  [[ "$out" == *"no formulae found"* || "$out" == *"no formulae or casks found"* || "$out" == *"no available formula"* ]]
}

search_brew() {
  local q="$1"
  (( HAVE_BREW )) || return 0
  say "→ brew: search"
  run_capture brew search -- "$q"
  if (( FULL )); then
    if (( RUN_RC == 0 )); then
      [[ -n "$RUN_OUT" ]] && printf "%s\n" "$RUN_OUT"
    else
      err "$RUN_OUT"
    fi
  else
    if (( RUN_RC == 0 )); then
      print_curated_results "$q" "brew" "$RUN_OUT"
    else
      if is_brew_no_matches "$RUN_OUT"; then
        say "(no matches)"
      else
        err "$RUN_OUT"
      fi
    fi
  fi
}

repo_pkg_available() {
  local pkg="$1"
  case "$TOOL" in
    apt)
      if apt-cache show "$pkg" 2>/dev/null | grep -q '^Package:'; then return 0; else return 1; fi
      ;;
    dnf)
      if dnf -q list --available "$pkg" 2>/dev/null | awk 'NR>1 {print $1}' | grep -q "^${pkg}[.]"; then return 0; else return 1; fi
      ;;
    pacman)
      if pacman -Si "$pkg" >/dev/null 2>&1; then return 0; else return 1; fi
      ;;
    zypper)
      if zypper --quiet info "$pkg" >/dev/null 2>&1; then return 0; else return 1; fi
      ;;
    rpm-ostree)
      if have rpm; then
        if rpm -q --whatprovides "$pkg" >/dev/null 2>&1; then return 0; else return 1; fi
      fi
      return 2
      ;;
    *)
      return 2
      ;;
  esac
}

flatpak_pick_appid() {
  local pkg="$1"
  local req="${pkg,,}"
  FP_APPID=""
  FP_REMOTE=""
  FP_WEAK_EXAMPLE=""
  if [[ "$pkg" == *.* ]]; then
    FP_APPID="$pkg"
  else
    local best_score=-1 best_app="" best_name="" best_quality=0
    while IFS=$'\t' read -r appid name; do
      [[ -n "$appid" ]] || continue
      local l_app="${appid,,}"
      local l_name="${name,,}"
      local tail="${l_app##*.}"
      local score=0
      local quality=0
      if [[ "$l_name" == "$req" ]]; then
        score=100; quality=1
      elif [[ "$tail" == "$req" ]]; then
        score=90; quality=1
      elif [[ "$l_name" =~ (^|[^a-z0-9])${req}([^a-z0-9]|$) ]] || [[ "$tail" =~ (^|[^a-z0-9])${req}([^a-z0-9]|$) ]]; then
        score=70; quality=1
      elif [[ "$l_name" == *"$req"* || "$l_app" == *"$req"* ]]; then
        score=40; quality=0
      fi
      if [[ "$req" =~ ^[a-z0-9]+$ && "$tail" == ${req}* && "$tail" != "$req" ]]; then
        (( score -= 25 ))
      fi
      if (( score > best_score )); then
        best_score=$score
        best_app="$appid"
        best_name="$name"
        best_quality=$quality
      fi
    done < <(flatpak search --columns=application,name -- "$pkg" 2>/dev/null | tr -s ' ')
    if (( best_score < 70 )); then
      FP_APPID=""
      FP_REMOTE=""
      FP_WEAK_EXAMPLE="$best_name"
      FP_HINT="Only partial matches found. Re-run with --choose or specify exact app-id."
      return 2
    fi
    FP_APPID="$best_app"
  fi
  [[ -n "$FP_APPID" ]] || return 1
  FP_REMOTE="$(flatpak remotes --columns=name 2>/dev/null | head -n1 | tr -d ' ' || true)"
  [[ -n "$FP_REMOTE" ]] || return 1
  if flatpak remote-info "$FP_REMOTE" "$FP_APPID" >/dev/null 2>&1; then return 0; else return 1; fi
}

brew_pick_kind() {
  local pkg="$1" class="$2"
  BREW_KIND=""
  local is_formula=0 is_cask=0
  brew info --formula "$pkg" >/dev/null 2>&1 && is_formula=1 || true
  brew info --cask "$pkg" >/dev/null 2>&1 && is_cask=1 || true
  if (( is_formula && is_cask )); then
    if [[ "$class" == "GUI" ]]; then BREW_KIND="cask"; else BREW_KIND="formula"; fi
  elif (( is_formula )); then
    BREW_KIND="formula"
  elif (( is_cask )); then
    BREW_KIND="cask"
  fi
  [[ -n "$BREW_KIND" ]]
}

is_installed_repo() {
  local pkg="$1"
  case "$TOOL" in
    apt) if dpkg -s "$pkg" >/dev/null 2>&1; then return 0; else return 1; fi ;;
    dnf|zypper|rpm-ostree) if rpm -q "$pkg" >/dev/null 2>&1; then return 0; else return 1; fi ;;
    pacman) if pacman -Qi "$pkg" >/dev/null 2>&1; then return 0; else return 1; fi ;;
    *) return 1 ;;
  esac
}

is_installed_dpkg() {
  local pkg="$1"
  if ! command -v dpkg >/dev/null 2>&1; then
    return 1
  fi
  local st
  st="$(dpkg -s "$pkg" 2>/dev/null | awk -F': ' '/^Status:/ {print $2; exit}')"
  [[ "$st" == *"install ok installed"* ]]
}

is_installed_flatpak() {
  local appid="$1"
  if flatpak info "$appid" >/dev/null 2>&1; then return 0; else return 1; fi
}

is_installed_brew() {
  local pkg="$1" kind="$2"
  if [[ "$kind" == "cask" ]]; then
    if brew list --cask "$pkg" >/dev/null 2>&1; then return 0; else return 1; fi
  else
    if brew list --formula "$pkg" >/dev/null 2>&1; then return 0; else return 1; fi
  fi
}

is_not_found_output() {
  local source="$1" out="${2,,}"
  case "$source" in
    repo)
      case "$TOOL" in
        apt) [[ "$out" == *"unable to locate package"* || "$out" == *"no installation candidate"* ]] ;;
        dnf) [[ "$out" == *"no match for argument"* || "$out" == *"unable to find a match"* || "$out" == *"no matching packages"* ]] ;;
        pacman) [[ "$out" == *"target not found"* ]] ;;
        zypper) [[ "$out" == *"no provider of"* || "$out" == *"not found in package names"* ]] ;;
        rpm-ostree) [[ "$out" == *"no match for argument"* || "$out" == *"packages not found"* ]] ;;
        *) return 1 ;;
      esac
      ;;
    flatpak)
      [[ "$out" == *"no matching refs found"* || "$out" == *"nothing matches"* || "$out" == *"no such ref"* ]]
      ;;
    brew)
      [[ "$out" == *"no available formula"* || "$out" == *"no formulae found"* || "$out" == *"is unavailable"* ]]
      ;;
    *) return 1 ;;
  esac
}

install_repo_pkg() {
  local pkg="$1"
  case "$TOOL" in
    rpm-ostree)
      say "→ repo: rpm-ostree install $pkg"
      run_capture sudo rpm-ostree install "$pkg"
      ;;
    apt)
      local y=()
      [[ "$YES" -eq 1 ]] && y+=(-y)
      if (( APT_UPDATED == 0 )); then
        run_capture sudo apt-get update
        (( RUN_RC == 0 )) && APT_UPDATED=1 || return $RUN_RC
      fi
      say "→ repo: apt-get install $pkg"
      run_capture sudo apt-get install "${y[@]}" "$pkg"
      ;;
    dnf)
      local y=()
      [[ "$YES" -eq 1 ]] && y+=(-y)
      say "→ repo: dnf install $pkg"
      run_capture sudo dnf install "${y[@]}" "$pkg"
      ;;
    pacman)
      local y=()
      [[ "$YES" -eq 1 ]] && y+=(--noconfirm)
      say "→ repo: pacman -S $pkg"
      run_capture sudo pacman -S --needed "${y[@]}" "$pkg"
      ;;
    zypper)
      local y=()
      [[ "$YES" -eq 1 ]] && y+=(-y)
      say "→ repo: zypper install $pkg"
      run_capture sudo zypper install "${y[@]}" "$pkg"
      ;;
    *)
      RUN_OUT="unsupported repo backend"
      RUN_RC=2
      ;;
  esac
  return $RUN_RC
}

install_flatpak_pkg() {
  local appid="$1" remote="$2"
  local y=()
  if [[ "$YES" -eq 1 || ! -t 0 ]]; then y+=(-y); fi
  say "→ flatpak: install $appid"
  run_capture flatpak install "${y[@]}" "$remote" "$appid"
}

install_brew_pkg() {
  local pkg="$1" kind="$2"
  if [[ "$kind" == "cask" ]]; then
    say "→ brew: install --cask $pkg"
    run_capture brew install --cask "$pkg"
  else
    say "→ brew: install $pkg"
    run_capture brew install "$pkg"
  fi
}

if [[ "$SEARCH" -eq 1 ]]; then
  RECAP_DIR="$(mktemp -d)"
  recap_terms=()
  recap_strong_files=()
  recap_weak_files=()
  i=0
  for q in "${PKGS[@]}"; do
    recap_terms+=("$q")
    recap_strong_files+=("$RECAP_DIR/term_${i}.strong")
    recap_weak_files+=("$RECAP_DIR/term_${i}.weak")
    : > "${recap_strong_files[$i]}"
    : > "${recap_weak_files[$i]}"
    say "→ Search: ${q}"
    if [[ "$TOOL" != "unknown" ]]; then
      search_repo "$q"
      recap_collect_repo "$q" "${recap_strong_files[$i]}" "${recap_weak_files[$i]}"
      say ""
    fi
    search_flatpak "$q"
    if (( HAVE_FLATPAK )); then
      recap_collect_flatpak "$q" "${recap_strong_files[$i]}"
      say ""
    fi
    search_brew "$q"
    if (( HAVE_BREW )); then
      recap_collect_brew "$q" "${recap_strong_files[$i]}"
      say ""
    fi
    i=$((i+1))
  done
  recap_print
  rm -rf "$RECAP_DIR"
  exit 0
fi

if [[ "$TOOL" == "unknown" && "$HAVE_FLATPAK" -eq 0 && "$HAVE_BREW" -eq 0 ]]; then
  err "$APP: unsupported system. ID=$ID ID_LIKE=$ID_LIKE"
  err "$APP: found no known package manager (apt/dnf/pacman/zypper/rpm-ostree/flatpak/brew)."
  exit 2
fi

installed_pkgs=()
skipped_installed=()
skipped_notfound=()
failed_pkgs=()

for pkg in "${PKGS[@]}"; do
  class="$(classify_pkg "$pkg")"
  say "→ $pkg"
  say "   class: $class"

  if [[ "$TOOL" == "apt" ]] && is_installed_dpkg "$pkg"; then
    say "⏭ $pkg (already installed via dpkg)"
    log_event "$(iso_now)" "$TOOL" "$pkg" "dpkg-local/manual-deb" "skip" "ok" "already installed"
    skipped_installed+=("$pkg")
    continue
  fi

  repo_avail=1
  if [[ "$TOOL" != "unknown" ]]; then
    if repo_pkg_available "$pkg"; then
      repo_avail=0
    else
      repo_avail=$?
    fi
  fi

  FP_APPID=""; FP_REMOTE=""
  flat_avail=1
  FP_HINT=""
  FP_WEAK_EXAMPLE=""
  if (( HAVE_FLATPAK )); then
    if flatpak_pick_appid "$pkg"; then
      flat_avail=0
    else
      flat_avail=$?
    fi
  fi

  BREW_KIND=""
  brew_avail=1
  if (( HAVE_BREW )); then
    if brew_pick_kind "$pkg" "$class"; then
      brew_avail=0
    else
      brew_avail=$?
    fi
  fi

  candidates=()
  if [[ "$TOOL" != "unknown" && $repo_avail -ne 1 ]]; then candidates+=("repo"); fi
  if (( HAVE_FLATPAK )) && [[ $flat_avail -eq 0 ]]; then candidates+=("flatpak"); fi
  if (( HAVE_BREW )) && [[ $brew_avail -eq 0 ]]; then candidates+=("brew"); fi

  if (( ${#candidates[@]} == 0 )); then
    if [[ $flat_avail -eq 2 ]]; then
      msg="⏭ $pkg (not found — only partial matches found"
      if [[ -n "${FP_WEAK_EXAMPLE:-}" ]]; then
        msg+=", e.g., ${FP_WEAK_EXAMPLE}"
      fi
      msg+="; use --choose or specify exact id)"
      say "$msg"
    else
      say "⏭ $pkg (not found in repo/flatpak/brew)"
    fi
    log_event "$(iso_now)" "$TOOL" "$pkg" "-" "skip" "ok" "not found"
    skipped_notfound+=("$pkg")
    continue
  fi

  source=""
  if [[ -z "$FORCE_SOURCE" ]]; then
    if (( ${#candidates[@]} == 1 )); then
      source="${candidates[0]}"
    elif (( CHOOSE == 1 )) && [[ -t 0 && -t 1 ]]; then
      say "→ Multiple sources for $pkg:"
      i=1
      for c in "${candidates[@]}"; do
        case "$c" in
          repo) say "  $i) repo ($TOOL)" ;;
          flatpak) say "  $i) flatpak ($FP_APPID)" ;;
          brew) say "  $i) brew ($BREW_KIND)" ;;
        esac
        i=$((i+1))
      done
      printf "Choose [1-%d]: " "${#candidates[@]}"
      IFS= read -r choice
      if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice>=1 && choice<=${#candidates[@]} )); then
        source="${candidates[$((choice-1))]}"
      fi
    fi
  fi

  if [[ -n "$FORCE_SOURCE" ]]; then
    source="$FORCE_SOURCE"
    if ! printf '%s\n' "${candidates[@]}" | grep -qx "$FORCE_SOURCE"; then
      say "⏭ $pkg (${FORCE_SOURCE} not found)"
      log_event "$(iso_now)" "$TOOL" "$pkg" "$FORCE_SOURCE" "skip" "ok" "not found"
      skipped_notfound+=("$pkg")
      continue
    fi
  fi

  if [[ -z "$source" ]]; then
    if [[ "$PREFER" != "auto" ]]; then
      order=("$PREFER" repo flatpak brew)
    else
      if is_atomic && [[ "$class" == "GUI" ]] && printf '%s\n' "${candidates[@]}" | grep -qx flatpak; then
        order=(flatpak repo brew)
      else
        order=(repo flatpak brew)
      fi
    fi
    for o in "${order[@]}"; do
      for c in "${candidates[@]}"; do
        if [[ "$c" == "$o" ]]; then source="$c"; break 2; fi
      done
    done
  fi

  if [[ "$source" == "repo" ]]; then
    if is_installed_repo "$pkg"; then
      say "⏭ $pkg (already installed via repo)"
      log_event "$(iso_now)" "$TOOL" "$pkg" "repo" "skip" "ok" "already installed"
      skipped_installed+=("$pkg")
      continue
    fi
    if install_repo_pkg "$pkg"; then
      :
    fi
  elif [[ "$source" == "flatpak" ]]; then
    if [[ -z "$FP_APPID" || -z "$FP_REMOTE" ]]; then
      say "⏭ $pkg (flatpak not found)"
      log_event "$(iso_now)" "$TOOL" "$pkg" "flatpak" "skip" "ok" "not found"
      skipped_notfound+=("$pkg")
      continue
    fi
    if is_installed_flatpak "$FP_APPID"; then
      say "⏭ $pkg (already installed via flatpak)"
      log_event "$(iso_now)" "$TOOL" "$pkg" "flatpak" "skip" "ok" "already installed"
      skipped_installed+=("$pkg")
      continue
    fi
    if install_flatpak_pkg "$FP_APPID" "$FP_REMOTE"; then
      :
    fi
  elif [[ "$source" == "brew" ]]; then
    if [[ -z "$BREW_KIND" ]]; then
      say "⏭ $pkg (brew not found)"
      log_event "$(iso_now)" "$TOOL" "$pkg" "brew" "skip" "ok" "not found"
      skipped_notfound+=("$pkg")
      continue
    fi
    if is_installed_brew "$pkg" "$BREW_KIND"; then
      say "⏭ $pkg (already installed via brew)"
      log_event "$(iso_now)" "$TOOL" "$pkg" "brew" "skip" "ok" "already installed"
      skipped_installed+=("$pkg")
      continue
    fi
    if install_brew_pkg "$pkg" "$BREW_KIND"; then
      :
    fi
  else
    say "⚠️ $pkg (no usable source selected)"
    log_event "$(iso_now)" "$TOOL" "$pkg" "-" "install" "failed" "no source"
    failed_pkgs+=("$pkg")
    if (( FAIL_FAST || ! CONTINUE_ON_ERROR )); then break; fi
    continue
  fi

  if [[ "$DRYRUN" -eq 1 ]]; then
    say "✅ $pkg (dry-run)"
    log_event "$(iso_now)" "$TOOL" "$pkg" "$source" "install" "ok" "dry-run"
    installed_pkgs+=("$pkg")
    continue
  fi

  if (( RUN_RC == 0 )); then
    say "✅ $pkg installed via $source"
    log_event "$(iso_now)" "$TOOL" "$pkg" "$source" "install" "ok" "installed"
    installed_pkgs+=("$pkg")
  else
    if is_not_found_output "$source" "$RUN_OUT"; then
      say "⏭ $pkg (not found via $source)"
      log_event "$(iso_now)" "$TOOL" "$pkg" "$source" "skip" "ok" "not found"
      skipped_notfound+=("$pkg")
    else
      hint="$(failure_hint "$RUN_OUT")"
      say "⚠️ $pkg failed ($hint)"
      log_event "$(iso_now)" "$TOOL" "$pkg" "$source" "install" "failed" "$hint"
      failed_pkgs+=("$pkg")
      if (( FAIL_FAST || ! CONTINUE_ON_ERROR )); then break; fi
    fi
  fi
done

say ""
say "Summary:"
say "Installed: ${installed_pkgs[*]:-none}"
say "Skipped: ${#skipped_installed[@]} already installed, ${#skipped_notfound[@]} not found"
say "Failed: ${failed_pkgs[*]:-none}"

if (( ${#failed_pkgs[@]} > 0 )); then
  exit 1
fi
exit 0
