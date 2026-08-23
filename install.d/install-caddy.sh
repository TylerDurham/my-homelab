#!/usr/bin/env bash
# Bootstraps the Caddy reverse proxy stack.
#
# Caddy runs in Docker (see docker/caddy), not as a system package — the build
# there compiles in the Cloudflare DNS plugin, which the distro package lacks.
set -euo pipefail

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

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CADDY_DIR="$REPO_ROOT/docker/caddy"

if ! command -v docker >/dev/null 2>&1; then
  error "docker not found — run install.d/install-docker.sh first."
  exit 1
fi

info "Creating the shared 'homelab' docker network (if absent)..."
docker network inspect homelab >/dev/null 2>&1 || docker network create homelab

if [[ ! -f "$CADDY_DIR/.env" ]]; then
  warn "No $CADDY_DIR/.env — copying from .env.example."
  warn "Fill in CADDY_DOMAIN, CF_API_TOKEN and PLEX_HOST before starting Caddy."
  cp "$CADDY_DIR/.env.example" "$CADDY_DIR/.env"
  exit 1
fi

info "Building Caddy with the Cloudflare DNS plugin (this compiles Go, give it a minute)..."
docker compose -f "$CADDY_DIR/docker-compose.yaml" --project-directory "$CADDY_DIR" build

info "Starting Caddy..."
docker compose -f "$CADDY_DIR/docker-compose.yaml" --project-directory "$CADDY_DIR" up -d

info "Done. Watch cert issuance with:"
info "  docker compose -f $CADDY_DIR/docker-compose.yaml logs -f caddy"
