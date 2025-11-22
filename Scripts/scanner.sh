#!/usr/bin/env bash
# scanner.sh - portable network scanner (Pi Zero 2W friendly)

set -Euo pipefail
set -o errtrace

VERSION="1.1.0"

CONCURRENCY=100
PING_TIMEOUT=1
TCP_TIMEOUT=1
PORTS=(22 80 443 5900 8080 111 5000)
VERBOSE=0
QUIET=0
NO_COLOR=0
CIDR=""
TMPDIR="${TMPDIR:-/tmp}/scanner.$$"

# colors
if [ "$NO_COLOR" -eq 0 ] 2>/dev/null; then
  C_RST=$'\033[0m'; C_RED=$'\033[0;31m'; C_GREEN=$'\033[0;32m'; C_BLUE=$'\033[0;34m'; C_YELLOW=$'\033[0;33m'
else
  C_RST=""; C_RED=""; C_GREEN=""; C_BLUE=""; C_YELLOW=""
fi

log()   { [ "$QUIET" -eq 0 ] || return 0; printf '%s\n' "$*"; }
info()  {
  if [ "$VERBOSE" -eq 1 ]; then
    printf '%s%s%s\n' "$C_BLUE" "$*" "$C_RST" >&2
  fi
}
warn()  { printf '%s%s%s\n' "$C_YELLOW" "$*" "$C_RST" >&2; }
err()   { printf '%s%s%s\n' "$C_RED" "$*" "$C_RST" >&2; }
die()   { err "ERROR: $*"; cleanup; exit 1; }

on_error() {
  local rc=$?
  local line=${1:-$LINENO}
  err "Script failed at line $line with status $rc"
  cleanup
  exit $rc
}
trap 'on_error $LINENO' ERR
trap 'cleanup' EXIT

cleanup(){
  { exec 9>&- 9<&-; } 2>/dev/null || true
  [ -d "$TMPDIR" ] && rm -rf "$TMPDIR"
}
cmd_exists(){ command -v "$1" >/dev/null 2>&1; }

usage(){
  cat <<EOF
scanner.sh $VERSION

Usage: $0 [options]
  -c, --concurrency N     Workers (default $CONCURRENCY)
  -p, --ports P1,P2,...   Ports to probe (default ${PORTS[*]})
  -t, --ping-timeout N    Ping timeout seconds (default $PING_TIMEOUT)
  -T, --tcp-timeout N     TCP connect timeout seconds (default $TCP_TIMEOUT)
  -r, --range CIDR        Network to scan (auto-detect if omitted)
  -v, --verbose           Verbose logging
  -q, --quiet             Minimal output
  --no-color              Disable color
  -h, --help              Show help
EOF
  exit 0
}

# Parse args
while (( $# )); do
  case "$1" in
    -c|--concurrency) CONCURRENCY="${2:?}"; shift 2;;
    -p|--ports) IFS=, read -r -a PORTS <<< "${2:?}"; shift 2;;
    -t|--ping-timeout) PING_TIMEOUT="${2:?}"; shift 2;;
    -T|--tcp-timeout) TCP_TIMEOUT="${2:?}"; shift 2;;
    -r|--range) CIDR="${2:?}"; shift 2;;
    -v|--verbose) VERBOSE=1; shift;;
    -q|--quiet) QUIET=1; shift;;
    --no-color) NO_COLOR=1; C_RST=""; C_RED=""; C_GREEN=""; C_BLUE=""; C_YELLOW=""; shift;;
    -h|--help) usage;;
    --) shift; break;;
    -*) die "Unknown option: $1";;
    *) break;;
  esac
done

mkdir -p "$TMPDIR"

# IP helpers (pure bash)
ip2int(){ local IFS=.; read -r a b c d <<<"$1"; printf '%u\n' "$(( (a<<24)+(b<<16)+(c<<8)+d ))"; }
int2ip(){ local i=$1; printf '%u.%u.%u.%u\n' "$(( (i>>24)&255 ))" "$(( (i>>16)&255 ))" "$(( (i>>8)&255 ))" "$(( i&255 ))"; }

get_local_addr() {
  if cmd_exists ip; then
    local line; line=$(ip route get 1.1.1.1 2>/dev/null || true)
    [[ $line =~ src[[:space:]]([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+) ]] && { printf '%s\n' "${BASH_REMATCH[1]}"; return 0; }
  fi
  if cmd_exists hostname; then
    local ip; ip=$(hostname -I 2>/dev/null | awk '{print $1}')
    [[ -n "$ip" ]] && { printf '%s\n' "$ip"; return 0; }
  fi
  if cmd_exists ifconfig; then
    local ip; ip=$(ifconfig 2>/dev/null | awk '/inet / && $2 != "127.0.0.1" {print $2; exit}')
    [[ -n "$ip" ]] && { printf '%s\n' "$ip"; return 0; }
  fi
  return 1
}

compute_cidr_from_ip() {
  local ip_or_cidr="$1"
  [[ "$ip_or_cidr" == */* ]] && { printf '%s\n' "$ip_or_cidr"; return; }
  if cmd_exists ip; then
    local line; line=$(ip -o -f inet addr show 2>/dev/null | awk -v me="$ip_or_cidr" '$0 ~ me {print $4; exit}')
    [[ -n "$line" ]] && { printf '%s\n' "$line"; return; }
  fi
  # fallback to /24 if mask unknown
  printf '%s/24\n' "$ip_or_cidr"
}

# Pure-bash CIDR to first/last host (no python/ipcalc)
cidr_to_range() {
  local cidr="$1"
  [[ "$cidr" =~ ^([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+)/([0-9]{1,2})$ ]] || return 1
  local ip="${BASH_REMATCH[1]}"; local prefix="${BASH_REMATCH[2]}"

  (( prefix >= 0 && prefix <= 32 )) || return 1
  local ip_i mask network first last
  ip_i=$(ip2int "$ip")
  if (( prefix == 0 )); then
    mask=0
  else
    mask=$(( 0xFFFFFFFF << (32 - prefix) & 0xFFFFFFFF ))
  fi
  network=$(( ip_i & mask ))
  local hostmax=$(( 0xFFFFFFFF ^ mask ))
  if (( prefix == 32 )); then
    first=$ip_i; last=$ip_i
  elif (( prefix == 31 )); then
    first=$network; last=$(( network + 1 ))
  else
    first=$(( network + 1 ))
    last=$(( network + hostmax - 1 ))
  fi
  printf '%s %s\n' "$(int2ip "$first")" "$(int2ip "$last")"
}

# Pinger and port checker
ping_host() {
  local ip="$1"
  ping -c1 -W"$PING_TIMEOUT" -q "$ip" >/dev/null 2>&1 && return 0
  ping -c1 -w"$PING_TIMEOUT" -q "$ip" >/dev/null 2>&1 && return 0
  return 1
}
tcp_check() {
  local ip="$1" port="$2"
  if cmd_exists nc; then
    nc -z -w "$TCP_TIMEOUT" "$ip" "$port" >/dev/null 2>&1
  elif cmd_exists timeout; then
    timeout "$TCP_TIMEOUT" bash -c ">/dev/tcp/$ip/$port" >/dev/null 2>&1
  else
    bash -c ">/dev/tcp/$ip/$port" >/dev/null 2>&1
  fi
}

# Detect CIDR
start_time=$(date +%s)
if [[ -z "${CIDR:-}" ]]; then
  local_ip=$(get_local_addr) || die "Could not detect local IP. Provide --range."
  if cmd_exists ip; then
    ip_and_prefix=$(ip -o -f inet addr show | awk -v me="$local_ip" '$0 ~ me {print $4; exit}')
    CIDR=$(compute_cidr_from_ip "${ip_and_prefix:-$local_ip}")
  else
    CIDR=$(compute_cidr_from_ip "$local_ip")
  fi
fi
info "Network: $CIDR"

# Get range (no process substitution to avoid ERR surprises)
range_out="$(cidr_to_range "$CIDR" || true)"
[[ -n "$range_out" ]] || die "Failed to compute range from $CIDR"
first_ip="${range_out%% *}"
last_ip="${range_out##* }"

# Guard against giant scans
max_hosts_allowed=4096
s_int=$(ip2int "$first_ip"); e_int=$(ip2int "$last_ip")
host_count=$(( e_int - s_int + 1 ))
if (( host_count > max_hosts_allowed )); then
  warn "CIDR $CIDR has $host_count hosts. Limiting to $max_hosts_allowed."
  e_int=$(( s_int + max_hosts_allowed - 1 ))
  last_ip="$(int2ip "$e_int")"
  host_count=$max_hosts_allowed
fi

info "Scanning $host_count hosts (concurrency=$CONCURRENCY) ..."

PING_AVAILABLE=1
if ! cmd_exists ping; then
  PING_AVAILABLE=0
  warn "ping command not detected; falling back to TCP-only reachability checks."
fi

# FIFO semaphore
sem_init(){
  mkfifo "$TMPDIR/sem"
  exec 9<>"$TMPDIR/sem"
  for ((i=0; i<CONCURRENCY; i++)); do printf '\n' >&9; done
}
sem_take(){ local _; read -r -u9 _ || true; }
sem_put(){ printf '\n' >&9; }
sem_init

do_probe() {
  local ip="$1"
  local alive=0
  local icmp_ok=0
  local tcp_ok=0
  local found=()

  if (( PING_AVAILABLE )); then
    if ping_host "$ip"; then
      icmp_ok=1
      info "icmp: $ip responded"
    fi
  fi

  for p in "${PORTS[@]}"; do
    if tcp_check "$ip" "$p"; then
      found+=("$p")
      tcp_ok=1
    fi
  done

  local ports="-"
  if (( tcp_ok )); then
    ports=$(printf '%s,' "${found[@]}")
    ports=${ports%,}
    info "open ports on $ip: $ports"
  fi

  (( icmp_ok || tcp_ok )) && alive=1
  printf '%s\t%d\t%s\t%d\t%d\n' "$ip" "$alive" "$ports" "$icmp_ok" "$tcp_ok"
  return 0
}

# Iterate without storing the entire range in a giant variable
for ((i=s_int; i<=e_int; i++)); do
  ip="$(int2ip "$i")"
  sem_take
  {
    result_path="$TMPDIR/result.$BASHPID"
    do_probe "$ip" >"$result_path" || printf '%s\t0\t-\t0\t0\n' "$ip" >"$result_path"
    sem_put
  } &
done
wait

{ exec 9>&- 9<&-; } 2>/dev/null || true

end_time=$(date +%s)
duration=$((end_time - start_time))

alive_count=0
declare -a alive_rows=()

if ls "$TMPDIR"/result.* >/dev/null 2>&1; then
  while IFS=$'\t' read -r ip alive ports icmp_flag tcp_flag; do
    [[ -z "$ip" ]] && continue
    if [[ "$alive" == "1" ]]; then
      alive_count=$((alive_count + 1))
      alive_rows+=("$ip|$ports|$icmp_flag|$tcp_flag")
    fi
  done < <(sort -t. -k1,1n -k2,2n -k3,3n -k4,4n "$TMPDIR"/result.*)
fi

ports_display=$(printf '%s ' "${PORTS[@]}")
ports_display=${ports_display% }
ports_display=${ports_display:-"-"}

if [ "$QUIET" -eq 0 ]; then
  summary_border="+------------------------------------------------------+"
  printf '%s\n' "${C_BLUE}${summary_border}${C_RST}"
  printf '%s\n' "$(printf '| %-8s | %s%-40s%s |' "Range" "$C_GREEN" "$CIDR" "$C_RST")"
  printf '%s\n' "$(printf '| %-8s | %s%-40s%s |' "Ports" "$C_YELLOW" "$ports_display" "$C_RST")"
  printf '%s\n' "$(printf '| %-8s | %s%-40s%s |' "Alive" "$C_GREEN" "$alive_count host(s)" "$C_RST")"
  printf '%s\n' "$(printf '| %-8s | %s%-40s%s |' "Elapsed" "$C_BLUE" "${duration}s" "$C_RST")"
  printf '%s\n' "${C_BLUE}${summary_border}${C_RST}"
  printf '\n'
fi

if (( alive_count > 0 )); then
  if [ "$QUIET" -eq 0 ]; then
    table_border="+--------------------+--------------+------------------------------+"
    printf '%s\n' "${C_BLUE}${table_border}${C_RST}"
    printf '%s\n' "$(printf '| %-18s | %-12s | %-28s |' "HOST" "STATUS" "OPEN PORTS")"
    printf '%s\n' "${C_BLUE}${table_border}${C_RST}"
  fi
  for entry in "${alive_rows[@]}"; do
    IFS='|' read -r ip ports icmp_flag tcp_flag <<<"$entry"
    status="ALIVE"
    ports_fmt="None"
    if [[ "$ports" != "-" ]]; then
      ports_fmt="${ports//,/ }"
      if [[ "$icmp_flag" == "1" ]]; then
        status="ICMP+TCP"
      else
        status="TCP"
      fi
      if [ ${#ports_fmt} -gt 28 ]; then
        ports_fmt="${ports_fmt:0:25}..."
      fi
    else
      status="ICMP"
      ports_fmt="None (ICMP only)"
    fi
    if [ "$QUIET" -eq 0 ]; then
      row=$(printf '| %s%-18s%s | %s%-12s%s | %-28s |' "$C_GREEN" "$ip" "$C_RST" "$C_YELLOW" "$status" "$C_RST" "$ports_fmt")
      printf '%s\n' "$row"
    else
      printf '%s\t%s\t%s\n' "$ip" "$status" "$ports_fmt"
    fi
  done
  if [ "$QUIET" -eq 0 ]; then
    printf '%s\n' "${C_BLUE}${table_border}${C_RST}"
  fi
else
  if [ "$QUIET" -eq 0 ]; then
    printf '%s\n' "${C_RED}No responsive hosts detected.${C_RST}"
  fi
fi

exit 0
