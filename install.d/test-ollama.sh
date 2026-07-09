
#!/usr/bin/env bash
# Quick check that Ollama's HTTP API is up and responding.

HOST="${OLLAMA_HOST:-http://localhost:11500}"

echo "Checking Ollama at $HOST ..."

if ! curl -s -o /dev/null -w "HTTP %{http_code}\n" "$HOST"; then
  echo "Ollama is not reachable at $HOST"
  exit 1
fi

echo
echo "Installed models:"
curl -s "$HOST/api/tags" | python3 -m json.tool 2>/dev/null || curl -s "$HOST/api/tags"

echo
echo "Test generation (model=llama3.2, override with MODEL=... env var):"
MODEL="${MODEL:-llama3.2}"
curl -s "$HOST/api/generate" -d "{\"model\": \"$MODEL\", \"prompt\": \"Say hello in five words.\", \"stream\": false}" | python3 -m json.tool 2>/dev/null || echo "Request failed — is '$MODEL' pulled? Try: ollama pull $MODEL"
