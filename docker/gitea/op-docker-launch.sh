#!/usr/bin/env bash
set -euo pipefail

# CHANGE TO APPROPRIATE OP ENV ID!
readonly OP_ENV_ID=kcpou6wxk2uqqec5q67pmsb6jq

# Load the token file so we can connect as the service account
token_file="/etc/op/$OP_ENV_ID.token"
export OP_SERVICE_ACCOUNT_TOKEN="$(<$token_file)"

op whoami                        # should show the service account
op environment read "$OP_ENV_ID" # show env

# launch docker using environment from op
exec op run --environment "$OP_ENV_ID" -- docker compose up -d --force-recreate
