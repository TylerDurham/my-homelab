#!/usr/bin/env bash
# Run this on the Framework desktop, in the same directory as your open-webui
# docker-compose.yml, AFTER you've added the searxng service block from
# searxng-compose-snippet.yml into that compose file.
set -e

mkdir -p ./searxng

echo "Starting searxng once to generate its default settings.yml..."
docker compose up -d searxng
sleep 5

SETTINGS="./searxng/settings.yml"

if [ ! -f "$SETTINGS" ]; then
  echo "settings.yml not found yet, waiting a bit longer..."
  sleep 5
fi

SECRET=$(openssl rand -hex 16)

echo "Enabling JSON output format..."
if grep -q "^\s*formats:" "$SETTINGS"; then
  # replace existing formats block with html + json
  python3 - "$SETTINGS" <<'PYEOF'
import sys, re
path = sys.argv[1]
with open(path) as f:
    content = f.read()
content = re.sub(r"formats:\n(\s+-\s.*\n)+", "formats:\n    - html\n    - json\n", content, count=1)
with open(path, "w") as f:
    f.write(content)
PYEOF
else
  # add a formats block under the search: section
  python3 - "$SETTINGS" <<'PYEOF'
import sys
path = sys.argv[1]
with open(path) as f:
    content = f.read()
content = content.replace("search:\n", "search:\n  formats:\n    - html\n    - json\n", 1)
with open(path, "w") as f:
    f.write(content)
PYEOF
fi

echo "Setting a random secret key..."
sed -i.bak "s/secret_key: \".*\"/secret_key: \"$SECRET\"/" "$SETTINGS"

echo "Restarting searxng to apply changes..."
docker compose restart searxng

echo ""
echo "Done. SearXNG should now be reachable at http://<framework-ip>:8080"
echo "and, from inside the open-webui container, at http://searxng:8080"
