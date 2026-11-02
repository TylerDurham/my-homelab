#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT=$(git rev-parse --show-toplevel)

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

usage() { echo "usage: $(basename "$0") <op-environment-id>" >&2; }

if [[ $# -ne 1 || -z "$1" ]]; then
  error "1Password environment ID not passed"
  usage
  exit 1
fi

readonly OP_ENV_ID=$1

source "$REPO_ROOT/install.d/lib/lib.sh"

container=$(select-container)

if [[ -z $container ]]; then
  warn "nothing selected"
  exit 1
fi

info "loading env for container '$container'"

# Load the token file so we can connect as the service account
token_file="/etc/op/$OP_ENV_ID.token"
if [[ ! -r "$token_file" ]]; then
  echo "error: token file '$token_file' not found or not readable" >&2
  exit 1
fi
export OP_SERVICE_ACCOUNT_TOKEN="$(<"$token_file")"

op whoami                        # should show the service account
op environment read "$OP_ENV_ID" # show env

# launch docker using environment from op
cd $container
exec op run --environment "$OP_ENV_ID" -- docker compose up -d --force-recreate
