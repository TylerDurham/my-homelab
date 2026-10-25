#!/usr/bin/env bash
set -euo pipefail

CWD=$(git rev-parse --show-toplevel)

# --- logging ------------------------------------------------------------
if [[ -t 2 ]]; then
  LOG_RESET=$'\033[0m'
  LOG_BLUE=$'\033[34m'
  LOG_YELLOW=$'\033[33m'
  LOG_RED=$'\033[31m'
  LOG_PURPLE=$'\033[35m'
else
  LOG_RESET='' LOG_BLUE='' LOG_GRAY='' LOG_YELLOW='' LOG_RED=''
fi

_log() { printf '%s[%s]%s %s\n' "$2" "$1" "$LOG_RESET" "${*:3}" >&2; }

info()  { _log INFO  "$LOG_BLUE"   "$@"; }
debug() { [[ -n "${DEBUG:-}" ]] || return 0; _log DEBUG "$LOG_PURPLE" "$@"; }
warn()  { _log WARN  "$LOG_YELLOW" "$@"; }
error() { _log ERROR "$LOG_RED"    "$@"; }
# -------------------------------------------------------------------------

module_name="${1:-}"
host_name="${2:-docker01.snork.co}"

if [[ -z "$module_name" ]]; then
  error "no module_name specified"
  exit 1
fi

module_path="$CWD/docker/$module_name"
if [[ ! -d "$module_path" ]]; then
  error "module directory '$module_path' does not exist"
  exit 1
fi

info "Deploying module '$module_name' to '$host_name'"

#scp -r "$module_path" "$host_name:/docker"

rsync -avn --exclude='.env' --exclude='.env.*' "$module_path" "$host_name:/docker"

