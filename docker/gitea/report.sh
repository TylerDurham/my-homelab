#!/usr/bin/env bash
#
# Status report for the running Gitea stack:
#   1. docker inspect     -> state, health, image, restarts, ports, mounts, networks
#   2. docker stats       -> CPU / memory / IO snapshot
#   3. docker exec gitea  -> OS, uptime, memory, disk, gitea version, healthz
#   4. docker exec db     -> postgres version, DB size, connections
#
# Needs: docker, jq. Override container names with GITEA_CONTAINER / DB_CONTAINER.
# Set DEBUG=1 to see raw inspect JSON.
set -euo pipefail

GITEA_CONTAINER="${GITEA_CONTAINER:-gitea}"
DB_CONTAINER="${DB_CONTAINER:-gitea-db}"

# --- logging ------------------------------------------------------------
if [[ -t 1 ]]; then
  LOG_RESET=$'\033[0m'
  LOG_BOLD=$'\033[1m'
  LOG_BLUE=$'\033[34m'
  LOG_GREEN=$'\033[32m'
  LOG_YELLOW=$'\033[33m'
  LOG_RED=$'\033[31m'
  LOG_PURPLE=$'\033[35m'
else
  LOG_RESET='' LOG_BOLD='' LOG_BLUE='' LOG_GREEN='' LOG_YELLOW='' LOG_RED='' LOG_PURPLE=''
fi

_log() { printf '%s[%s]%s %s\n' "$2" "$1" "$LOG_RESET" "${*:3}" >&2; }

debug() {
  [[ -n "${DEBUG:-}" ]] || return 0
  _log DEBUG "$LOG_PURPLE" "$@"
}
warn() { _log WARN "$LOG_YELLOW" "$@"; }
error() { _log ERROR "$LOG_RED" "$@"; }

header() { printf '\n%s== %s ==%s\n' "$LOG_BOLD$LOG_BLUE" "$*" "$LOG_RESET"; }
kv() { printf '  %-14s %s\n' "$1" "$2"; }
# -------------------------------------------------------------------------

# Colour a state/health word: green if good, red otherwise.
status_colour() {
  case "$1" in
  running | healthy) printf '%s%s%s' "$LOG_GREEN" "$1" "$LOG_RESET" ;;
  starting | n/a) printf '%s%s%s' "$LOG_YELLOW" "$1" "$LOG_RESET" ;;
  *) printf '%s%s%s' "$LOG_RED" "$1" "$LOG_RESET" ;;
  esac
}

# Indent multi-line command output under a section.
indent() { sed 's/^/    /'; }

# Run a command in a container; on failure print a placeholder instead of
# aborting the whole report. Set DEBUG=1 to see why it failed.
dexec() {
  local container=$1 out
  shift
  if out=$(docker exec "$container" "$@" 2>&1); then
    printf '%s\n' "$out"
  else
    debug "$container: '$*' failed: $out"
    echo "(unavailable)"
  fi
}

# --- docker inspect -----------------------------------------------------
# Note: Config.Env is deliberately never printed — it holds the DB password.
report_inspect() {
  local name=$1 json
  json=$(docker inspect "$name")
  debug "inspect $name: $(jq -c '.[0] | del(.Config.Env)' <<<"$json")"

  header "$name: container"
  kv "Image" "$(jq -r '.[0].Config.Image' <<<"$json")"
  kv "Image ID" "$(jq -r '.[0].Image[7:19]' <<<"$json")"
  kv "State" "$(status_colour "$(jq -r '.[0].State.Status' <<<"$json")")"
  kv "Health" "$(status_colour "$(jq -r '.[0].State.Health.Status // "n/a"' <<<"$json")")"
  kv "Started" "$(jq -r '.[0].State.StartedAt' <<<"$json")"
  kv "Restarts" "$(jq -r '.[0].RestartCount' <<<"$json")"
  kv "Restart pol." "$(jq -r '.[0].HostConfig.RestartPolicy.Name' <<<"$json")"

  local failing
  failing=$(jq -r '.[0].State.Health.FailingStreak // 0' <<<"$json")
  if ((failing > 0)); then
    warn "$name healthcheck failing streak: $failing"
    jq -r '.[0].State.Health.Log[-1].Output' <<<"$json" | indent
  fi

  echo "  Ports:"
  jq -r '.[0].NetworkSettings.Ports // {} | to_entries[]
    | "\(.key) -> \((.value // []) | map("\(.HostIp):\(.HostPort)") | join(", ") | if . == "" then "(not published)" else . end)"' \
    <<<"$json" | indent

  echo "  Networks:"
  jq -r '.[0].NetworkSettings.Networks | to_entries[] | "\(.key) (\(.value.IPAddress))"' <<<"$json" | indent

  echo "  Mounts:"
  jq -r '.[0].Mounts[] | "\(.Source) -> \(.Destination)\(if .RW then "" else " (ro)" end)"' <<<"$json" | indent
}

# --- gitea container ----------------------------------------------------
report_gitea() {
  header "$GITEA_CONTAINER: system"
  kv "OS" "$(dexec "$GITEA_CONTAINER" sh -c '. /etc/os-release && echo "$PRETTY_NAME"')"
  kv "Kernel" "$(dexec "$GITEA_CONTAINER" uname -r)"
  kv "Uptime" "$(dexec "$GITEA_CONTAINER" uptime)"
  # Run as git so gitea doesn't complain about being root.
  kv "Gitea" "$(docker exec -u git "$GITEA_CONTAINER" gitea --version 2>/dev/null || echo '(unavailable)')"
  kv "healthz" "$(dexec "$GITEA_CONTAINER" curl -fsS http://localhost:3000/api/healthz | jq -r '.status // .' 2>/dev/null || echo '(unreachable)')"

  echo "  Memory:"
  dexec "$GITEA_CONTAINER" free -m | indent

  echo "  Disk (/data):"
  dexec "$GITEA_CONTAINER" df -h /data | indent

  echo "  Data usage:"
  dexec "$GITEA_CONTAINER" sh -c 'du -sh /data/git/repositories /data/git/lfs /data/gitea/packages 2>/dev/null; true' | indent

  echo "  Processes:"
  dexec "$GITEA_CONTAINER" ps -o pid,user,rss,args | indent
}

# --- postgres container -------------------------------------------------
# POSTGRES_USER / POSTGRES_DB are already set in the db container's env, so
# expand them there rather than reading .env on the host.
psql_q() {
  docker exec "$DB_CONTAINER" sh -c \
    "psql -U \"\$POSTGRES_USER\" -d \"\$POSTGRES_DB\" -tAc \"$1\"" 2>/dev/null ||
    echo "(unavailable)"
}

report_db() {
  header "$DB_CONTAINER: postgres"
  kv "Version" "$(psql_q 'SHOW server_version')"
  kv "DB size" "$(psql_q 'SELECT pg_size_pretty(pg_database_size(current_database()))')"
  kv "Connections" "$(psql_q 'SELECT count(*) FROM pg_stat_activity WHERE datname = current_database()')"
  kv "Ready" "$(dexec "$DB_CONTAINER" sh -c 'pg_isready -U "$POSTGRES_USER" -d "$POSTGRES_DB"')"

  echo "  Disk (data dir):"
  dexec "$DB_CONTAINER" df -h /var/lib/postgresql/data | indent
}

# --- main ---------------------------------------------------------------
command -v jq >/dev/null || {
  error "jq is required"
  exit 1
}

printf '%sGitea stack report%s — %s on %s\n' "$LOG_BOLD" "$LOG_RESET" "$(date '+%F %T')" "$(uname -n)"

for c in "$GITEA_CONTAINER" "$DB_CONTAINER"; do
  if ! docker inspect "$c" >/dev/null 2>&1; then
    error "Container '$c' not found"
    exit 1
  fi
done

report_inspect "$GITEA_CONTAINER"
report_inspect "$DB_CONTAINER"

header "Resource usage"
docker stats --no-stream \
  --format 'table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.NetIO}}\t{{.BlockIO}}\t{{.PIDs}}' \
  "$GITEA_CONTAINER" "$DB_CONTAINER" | indent

if [[ "$(docker inspect -f '{{.State.Running}}' "$GITEA_CONTAINER")" == "true" ]]; then
  report_gitea
else
  warn "$GITEA_CONTAINER is not running; skipping exec checks"
fi

if [[ "$(docker inspect -f '{{.State.Running}}' "$DB_CONTAINER")" == "true" ]]; then
  report_db
else
  warn "$DB_CONTAINER is not running; skipping exec checks"
fi
