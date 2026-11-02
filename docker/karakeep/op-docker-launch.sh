#!/usr/bin/env bash
set -euo pipefail

usage() { echo "usage: $(basename "$0") <op-environment-id>" >&2; }

if [[ $# -ne 1 || -z "$1" ]]; then
  echo "error: 1Password environment ID not passed" >&2
  usage
  exit 1
fi
readonly OP_ENV_ID=$1

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
exec op run --environment "$OP_ENV_ID" -- docker compose up -d --force-recreate

