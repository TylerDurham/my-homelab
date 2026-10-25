#!/usr/bin/env bash
#
# Smoke test for the mcp-searxng server:
#   1. GET /health        -> is the server listening?
#   2. initialize         -> open an MCP session
#   3. tools/list         -> print the tools the server exposes
#   4. tools/call         -> run searxng_web_search for "test"
#
# Needs: curl, jq. Reads SEARXNG_MCP_URL + SEARXNG_MCP_TOKEN from .env.
# Set DEBUG=1 to see raw responses.
set -euo pipefail

ROOTD=$(git rev-parse --show-toplevel)
CWD="$ROOTD/docker/mcp-searxng"
ENV="$CWD/.env"

# --- logging ------------------------------------------------------------
if [[ -t 2 ]]; then
  LOG_RESET=$'\033[0m'
  LOG_BLUE=$'\033[34m'
  LOG_YELLOW=$'\033[33m'
  LOG_RED=$'\033[31m'
  LOG_PURPLE=$'\033[35m'
else
  LOG_RESET='' LOG_BLUE='' LOG_YELLOW='' LOG_RED='' LOG_PURPLE=''
fi

_log() { printf '%s[%s]%s %s\n' "$2" "$1" "$LOG_RESET" "${*:3}" >&2; }

info() { _log INFO "$LOG_BLUE" "$@"; }
debug() {
  [[ -n "${DEBUG:-}" ]] || return 0
  _log DEBUG "$LOG_PURPLE" "$@"
}
warn() { _log WARN "$LOG_YELLOW" "$@"; }
error() { _log ERROR "$LOG_RED" "$@"; }
# -------------------------------------------------------------------------

source "$ENV"

BASE_URL="${SEARXNG_MCP_URL%/}"
MCP_URL="$BASE_URL/mcp"
HEADERS=$(mktemp)
trap 'rm -f "$HEADERS"' EXIT

# POST a JSON-RPC message to /mcp and print the JSON body.
# The server may answer as plain JSON or as an SSE stream ("data: {...}"),
# so strip any "data: " prefix and keep only the JSON lines.
mcp_post() {
  local body=$1
  local session_args=()
  [[ -n "${SESSION_ID:-}" ]] && session_args=(-H "Mcp-Session-Id: $SESSION_ID")

  curl -sS --fail-with-body -X POST "$MCP_URL" \
    -H "Content-Type: application/json" \
    -H "Accept: application/json, text/event-stream" \
    -H "Authorization: Bearer $SEARXNG_MCP_HTTP_AUTH_TOKEN" \
    "${session_args[@]}" \
    -D "$HEADERS" \
    -d "$body" |
    sed -n 's/^data: //; /^{/p'
}

# --- 1. is it listening? -------------------------------------------------
info "Checking $BASE_URL/health"
status=$(curl -sS -o /dev/null -w '%{http_code}' \
  -H "Authorization: Bearer $SEARXNG_MCP_HTTP_AUTH_TOKEN" \
  "$BASE_URL/health")

if [[ "$status" != "200" ]]; then
  error "Health check returned HTTP $status"
  exit 1
fi
info "Server is up (HTTP 200)"

# --- 2. initialize a session --------------------------------------------
info "Initializing MCP session"
init=$(mcp_post '{
  "jsonrpc": "2.0", "id": 1, "method": "initialize",
  "params": {
    "protocolVersion": "2025-06-18",
    "capabilities": {},
    "clientInfo": { "name": "test-mcp.sh", "version": "1.0" }
  }
}')
debug "initialize: $init"

SESSION_ID=$(grep -i '^mcp-session-id:' "$HEADERS" | cut -d' ' -f2 | tr -d '\r' || true)
info "Connected to $(jq -r '.result.serverInfo | "\(.name) \(.version)"' <<<"$init")"
debug "Session: ${SESSION_ID:-<none>}"

# Tell the server we're ready (a notification, so no response body).
mcp_post '{ "jsonrpc": "2.0", "method": "notifications/initialized" }' >/dev/null

# --- 3. list tools -------------------------------------------------------
info "Listing tools"
tools=$(mcp_post '{ "jsonrpc": "2.0", "id": 2, "method": "tools/list" }')
debug "tools/list: $tools"

jq -r '.result.tools[] | "  - \(.name): \(.description | split(". ")[0])"' <<<"$tools"

# --- 4. call searxng_web_search -----------------------------------------
info "Calling searxng_web_search (query: \"test\")"
search=$(mcp_post '{
  "jsonrpc": "2.0", "id": 3, "method": "tools/call",
  "params": { "name": "searxng_web_search", "arguments": { "query": "test" } }
}')
debug "tools/call: $search"

if [[ "$(jq -r '.result.isError // false' <<<"$search")" == "true" ]]; then
  error "Search failed: $(jq -r '.result.content[0].text' <<<"$search")"
  exit 1
fi

# Results come back as text content; show the first 20 lines.
jq -r '.result.content[].text' <<<"$search" | head -n 20
