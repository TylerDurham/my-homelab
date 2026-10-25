# mcp-searxng

Self-hosted [mcp-searxng](https://github.com/ihor-sokoliuk/mcp-searxng) server for the snork.co homelab. It gives MCP clients (OpenCode, primarily) private web search backed by the homelab's own SearXNG instance.

The server runs as a long-lived **HTTP** service on the `homelab` Docker network, sits behind Caddy at `searxng-mcp.snork.co`, and requires a bearer token.

```
OpenCode ──HTTPS + Bearer token──▶ Caddy (searxng-mcp.snork.co)
                                     │
                                     ▼  homelab network
                              mcp-searxng:3000 ──HTTP JSON API──▶ SearXNG
```

## Files

| File | Purpose |
|---|---|
| `docker-compose.yaml` | Service definition: HTTP mode, healthcheck, log volume, hardening, resource limits |
| `.env` | Runtime config and secrets. **Not committed.** Copy from `.env.example` |
| `logs/` | Bind-mounted log directory. Created by hand, owned by UID 1000 |

## Prerequisites

- The external Docker network exists: `docker network create homelab`.
- SearXNG has JSON output enabled. Without it, every search fails with a 403. In SearXNG's `settings.yml`:

  ```yaml
  search:
    formats:
      - html
      - json
  ```

## Setup

```bash
cp .env.example .env
openssl rand -hex 32          # paste into MCP_HTTP_AUTH_TOKEN
$EDITOR .env                  # set SEARXNG_URL, check ALLOWED_HOSTS

mkdir -p logs && sudo chown 1000:1000 logs   # image runs as UID 1000
docker compose up -d
docker compose ps             # wait for "healthy"
```

If Docker creates `logs/` itself, it will be owned by root and the container won't be able to write to it.

## How it's configured

### HTTP transport

The server speaks stdio by default. Setting `MCP_HTTP_PORT` switches it to HTTP, and `MCP_HTTP_HOST` must be `0.0.0.0` inside a container because the default is `127.0.0.1`. Both are pinned in `docker-compose.yaml` rather than `.env`, so a typo there can't quietly drop the server back to stdio.

Endpoints:

- `POST /mcp`: the MCP protocol (legacy clients may also use `GET`/`DELETE`)
- `GET /health`: health check

### Logging

The server only writes to stdout/stderr and has no log-file option. The compose file overrides the entrypoint to pipe it through `tee`:

```yaml
entrypoint: ["/bin/sh", "-c"]
command: ["node dist/cli.js 2>&1 | tee -a /logs/mcp-searxng.log"]
```

That gives you both:

- `docker compose logs -f`, rotated by the json-file driver (10 MB × 3)
- `./logs/mcp-searxng.log` on the host. **Not rotated.** Truncate it or add a logrotate rule.

`init: true` with `TINI_KILL_PROCESS_GROUP=1` makes sure `docker compose down` stops both `node` and `tee`.

Nothing else is persisted. Search and URL caches are in-memory and reset on restart.

### Hardening

`MCP_HTTP_HARDEN=true` turns on bearer-token auth plus Host/Origin enforcement. These three must be set together:

| Variable | Value / notes |
|---|---|
| `MCP_HTTP_AUTH_TOKEN` | Random 32-byte hex. Clients send it as `Authorization: Bearer <token>` |
| `MCP_HTTP_ALLOWED_ORIGINS` | `https://searxng-mcp.snork.co`. OpenCode sends no `Origin`, which is allowed. The value is required, though |
| `MCP_HTTP_ALLOWED_HOSTS` | Matched **exactly** against the `Host` header, **port included**. Setting it replaces the defaults |

Current allowed hosts:

- `searxng-mcp.snork.co`: via Caddy, which preserves `Host`
- `192.168.1.10:8004`: direct LAN access to the published port. Update this if the stack moves hosts
- `127.0.0.1:3000`, `localhost:3000`: the in-container healthcheck

`MCP_HTTP_TRUST_PROXY=1` trusts one proxy hop (Caddy), so rate limiting and logs see real client IPs.

The container also runs with `read_only: true`, a tmpfs `/tmp`, `cap_drop: ALL`, `no-new-privileges`, and limits of 0.5 CPU / 384 MB. That sits in upstream's small-to-balanced profile for 1–4 clients.

### Ports

The container listens on `3000`. On the host it's published as `8004`, because Homepage already uses 3000. If everything goes through Caddy, the `ports:` block can be removed.

### `.env` reference

| Variable | Default here | Notes |
|---|---|---|
| `SEARXNG_URL` | `http://searxng:8080` | Container name if on `homelab`, otherwise the LAN URL. Supports `;`-separated replicas |
| `MCP_HTTP_HARDEN` | `true` | |
| `MCP_HTTP_AUTH_TOKEN` | — | Secret |
| `MCP_HTTP_ALLOWED_ORIGINS` | `https://searxng-mcp.snork.co` | |
| `MCP_HTTP_ALLOWED_HOSTS` | see above | |
| `MCP_HTTP_TRUST_PROXY` | `1` | Remove if only accessed directly |
| `SEARXNG_DEFAULT_LANGUAGE` | `en` | |
| `SEARXNG_MAX_RESULTS` | `10` | 1–20 |
| `SEARXNG_MAX_RESULT_CHARS` | `500` | Snippet length cap |
| `SEARXNG_LITE_TOOLS` | unset | `true` for smaller tool schemas (small local models) |
| `MCP_PUBLISH_PORT` | `8004` | Compose interpolation only |

The full list of variables is in [upstream's CONFIGURATION.md](https://github.com/ihor-sokoliuk/mcp-searxng/blob/main/CONFIGURATION.md).

## Caddy

Add this to the wildcard site block in the Caddyfile:

```caddy
@searxngmcp host {$SEARXNG_MCP_HOST}
handle @searxngmcp {
	import secure_headers
	reverse_proxy mcp-searxng:3000 {
		flush_interval -1   # MCP responses can stream over SSE
	}
}
```

Add this to Caddy's `.env`:

```env
SEARXNG_MCP_HOST="searxng-mcp.${CADDY_DOMAIN}"
```

Then add a LAN DNS record for `searxng-mcp.snork.co`. If this stack isn't on the same Docker host as Caddy, proxy to `<host-ip>:8004` instead of the container name.

## OpenCode client

In `~/.config/opencode/opencode.json`:

```json
{
  "$schema": "https://opencode.ai/config.json",
  "mcp": {
    "searxng": {
      "type": "remote",
      "url": "https://searxng-mcp.snork.co/mcp",
      "enabled": true,
      "headers": {
        "Authorization": "Bearer {env:SEARXNG_MCP_TOKEN}"
      }
    }
  }
}
```

Export `SEARXNG_MCP_TOKEN` in your shell so the token stays out of the config file.

Using it:

- Ask normally ("search the web for…"). To force the tool, name it: "use searxng to…".
- To make it the default, add a line to `~/.config/opencode/AGENTS.md`: *"For web searches, use the searxng tools."*
- Tools exposed: `searxng_web_search`, `web_url_read`.
- If the model never calls the tool, it probably handles tool calling poorly. Try a stronger model.

## Operations

```bash
docker compose ps                         # health status
docker compose logs -f                    # live logs
tail -f logs/mcp-searxng.log              # same, from the host file
docker compose pull && docker compose up -d   # update

# health check from the LAN
curl -H "Authorization: Bearer $SEARXNG_MCP_TOKEN" http://192.168.1.10:8004/health
```

To call the tools by hand without OpenCode, use the [MCP Inspector](https://github.com/modelcontextprotocol/inspector): `npx @modelcontextprotocol/inspector`. Connect it to `https://searxng-mcp.snork.co/mcp` as a Streamable HTTP server, with the bearer token as a header.

## Troubleshooting

| Symptom | Likely cause |
|---|---|
| Container restarts, nothing in `logs/` | `logs/` owned by root. Run `chown 1000:1000 logs` |
| Searches return 403 | JSON not enabled in SearXNG `settings.yml` |
| 403 before auth, from the server | `Host` not in `MCP_HTTP_ALLOWED_HOSTS` (check the port), or a bad `Origin` |
| 401 | Missing or wrong bearer token |
| 429 | Rate limit hit. Tune the `MCP_RATE_*` variables |
| Healthy, but OpenCode shows it failed | Wrong URL (it needs the `/mcp` path) or the token env var isn't exported |
| Empty results | Check SearXNG's own logs. The upstream engines may be blocked or failing |
| `web_url_read` refuses LAN URLs | Private URLs are blocked by default. Set `MCP_HTTP_ALLOW_PRIVATE_URLS=true` only if that's intended |

## References

- [mcp-searxng](https://github.com/ihor-sokoliuk/mcp-searxng) ([configuration reference](https://github.com/ihor-sokoliuk/mcp-searxng/blob/main/CONFIGURATION.md))
- [OpenCode MCP servers](https://opencode.ai/docs/mcp-servers)
- [SearXNG settings](https://docs.searxng.org/admin/settings/index.html)
