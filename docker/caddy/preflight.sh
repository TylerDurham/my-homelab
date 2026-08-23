#!/usr/bin/env bash
# Preflight checks before the first Caddy build.
#
# Every failure below is one that would otherwise surface as a failed ACME
# challenge — and failed challenges count against Let's Encrypt's rate limit
# (5 duplicate certs per week), so it's worth catching them here instead.
set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"

# --- logging ------------------------------------------------------------
if [[ -t 2 ]]; then
  LOG_RESET=$'\033[0m'
  LOG_BLUE=$'\033[34m'
  LOG_YELLOW=$'\033[33m'
  LOG_RED=$'\033[31m'
  LOG_GREEN=$'\033[32m'
else
  LOG_RESET='' LOG_BLUE='' LOG_YELLOW='' LOG_RED='' LOG_GREEN=''
fi

_log() { printf '%s[%s]%s %s\n' "$2" "$1" "$LOG_RESET" "${*:3}" >&2; }
info()  { _log INFO  "$LOG_BLUE"   "$@"; }
ok()    { _log OK    "$LOG_GREEN"  "$@"; }
warn()  { _log WARN  "$LOG_YELLOW" "$@"; }
error() { _log ERROR "$LOG_RED"    "$@"; }
# -------------------------------------------------------------------------

FAILED=0
fail() { error "$@"; FAILED=1; }

BODY=$(mktemp); trap 'rm -f "$BODY"' EXIT

# Calls the Cloudflare API. Body lands in $BODY, HTTP status is echoed.
# Deliberately not `curl -f`: on a 4xx we want Cloudflare's error message,
# and -f discards the response body along with the exit status.
api() {
  local method=$1 path=$2
  curl -sS -X "$method" -o "$BODY" -w '%{http_code}' --max-time 10 \
    -H "Authorization: Bearer ${CF_API_TOKEN}" \
    -H 'Content-Type: application/json' \
    "${@:3}" \
    "https://api.cloudflare.com/client/v4${path}" 2>/dev/null
}

# Prints whatever Cloudflare said went wrong, indented.
api_errors() { jq -r '.errors[]?.message' "$BODY" 2>/dev/null | sed 's/^/       /' >&2; }

if [[ ! -f .env ]]; then
  error "No .env here. Copy .env.example and fill it in first."
  exit 1
fi

set -a; . ./.env; set +a

: "${CADDY_DOMAIN:?CADDY_DOMAIN not set in .env}"
: "${CF_API_TOKEN:?CF_API_TOKEN not set in .env}"

# The zone is the registrable domain, which may be a parent of CADDY_DOMAIN
# (CADDY_DOMAIN=home.example.com -> zone example.com).
ZONE="${CF_ZONE:-$(echo "$CADDY_DOMAIN" | awk -F. '{print $(NF-1)"."$NF}')}"

info "Domain: $CADDY_DOMAIN (wildcard *.$CADDY_DOMAIN)   Zone: $ZONE"
echo >&2

# --- 1. nameserver delegation -------------------------------------------
# Asked over DoH so this works without dig/bind-tools installed.
info "1/4  Checking nameserver delegation for $ZONE ..."
NS=$(curl -fsS --max-time 10 -H 'accept: application/dns-json' \
      "https://cloudflare-dns.com/dns-query?name=${ZONE}&type=NS" 2>/dev/null \
      | jq -r '.Answer[]?.data' | sed 's/\.$//')

if [[ -z "$NS" ]]; then
  fail "     No NS records returned. Delegation hasn't propagated yet."
elif grep -qi 'cloudflare\.com' <<<"$NS"; then
  ok "     Delegated to Cloudflare:"
  sed 's/^/       /' <<<"$NS" >&2
else
  warn "     Not yet on Cloudflare — currently:"
  sed 's/^/       /' <<<"$NS" >&2
  warn "     Nameserver changes can take a few hours. Re-run this later."
  FAILED=1
fi
echo >&2

# --- 2. token can see the zone ------------------------------------------
# This runs before the token-status check because it's the stronger test —
# a 200 here means the token authenticated AND has Zone:Read on this zone —
# and because it's what yields the account id that check 3 needs.
info "2/4  Checking token has access to zone $ZONE ..."
CODE=$(api GET "/zones?name=${ZONE}")
ZONE_ID=$(jq -r '.result[0].id // empty' "$BODY" 2>/dev/null)
ZONE_STATUS=$(jq -r '.result[0].status // empty' "$BODY" 2>/dev/null)
ACCOUNT_ID=$(jq -r '.result[0].account.id // empty' "$BODY" 2>/dev/null)

if [[ "$CODE" == 401 || "$CODE" == 403 ]]; then
  fail "     Token rejected (HTTP $CODE). Check CF_API_TOKEN in .env."
  api_errors
elif [[ -z "$ZONE_ID" ]]; then
  fail "     Token authenticated, but can't see zone '$ZONE' (HTTP $CODE)."
  fail "     Needs Zone:Read scoped to include this zone."
  api_errors
else
  ok "     Zone found (id ${ZONE_ID:0:8}…, status: $ZONE_STATUS)"
  [[ "$ZONE_STATUS" == "active" ]] || \
    warn "     Zone is '$ZONE_STATUS', not 'active' — Cloudflare hasn't confirmed delegation yet."
fi
echo >&2

# --- 3. token status ----------------------------------------------------
# Two kinds of token exist and they verify at different endpoints:
# account-owned tokens (the `cfat_` prefix) are invisible to
# /user/tokens/verify, which answers a flat 401 "Invalid API Token" for them.
# Checking the wrong one reads as a dead token when it's perfectly good.
info "3/4  Checking token status ..."
if [[ -n "$ACCOUNT_ID" ]]; then
  CODE=$(api GET "/accounts/${ACCOUNT_ID}/tokens/verify")
  [[ "$CODE" == 200 ]] || CODE=$(api GET "/user/tokens/verify")
else
  CODE=$(api GET "/user/tokens/verify")
fi

STATUS=$(jq -r '.result.status // empty' "$BODY" 2>/dev/null)
case "$STATUS" in
  active)  ok "     Token is active." ;;
  expired) fail "     Token has expired — issue a new one." ;;
  "")      warn "     Couldn't read token status (HTTP $CODE); check 2 already proved it works."
           api_errors ;;
  *)       fail "     Token status is '$STATUS', expected 'active'." ;;
esac
echo >&2

# --- 4. DNS write permission --------------------------------------------
# Reading records only proves DNS:Read. DNS-01 needs to *write* a TXT record,
# so write one — the same thing Caddy will do — and clean it up.
info "4/4  Checking DNS write permission ..."
if [[ -n "$ZONE_ID" ]]; then
  REC="_caddy-preflight.${CADDY_DOMAIN}"
  CODE=$(api POST "/zones/${ZONE_ID}/dns_records" \
          --data "{\"type\":\"TXT\",\"name\":\"${REC}\",\"content\":\"caddy preflight $(date +%s)\",\"ttl\":60}")
  REC_ID=$(jq -r '.result.id // empty' "$BODY" 2>/dev/null)

  if [[ -z "$REC_ID" ]]; then
    fail "     Can't create TXT records (HTTP $CODE). Needs Zone:DNS:Edit."
    api_errors
  else
    ok "     Wrote test TXT record $REC"
    CODE=$(api DELETE "/zones/${ZONE_ID}/dns_records/${REC_ID}")
    if [[ "$CODE" == 200 ]]; then
      ok "     Cleaned it up again."
    else
      warn "     Created it but couldn't delete it (HTTP $CODE)."
      warn "     Remove '$REC' by hand in the Cloudflare dashboard."
      api_errors
    fi
  fi
else
  warn "     Skipped — no zone id."
fi
echo >&2

if [[ $FAILED -eq 0 ]]; then
  ok "All checks passed. Safe to run: docker compose build && docker compose up -d"
else
  error "Some checks failed — fix these before starting Caddy."
  exit 1
fi
