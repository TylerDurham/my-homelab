# my-homelab

Docker Compose stacks and bootstrap scripts for my self-hosted homelab.
Each service lives in its own directory under `docker/`, gets deployed to a
Docker host with one script, and sits behind a single Caddy reverse proxy
that serves every service over HTTPS on a LAN-only subdomain.

## How it fits together

```
            LAN client
                │  https://<service>.<domain>
                ▼
┌──────────────────────────────────────────────────────────┐
│ Caddy  (wildcard cert via Cloudflare DNS-01)             │
└──────────────────────────────────────────────────────────┘
                │  shared external `homelab` network / host ports
     ┌──────────┼───────────┬────────────┬──────────────┐
     ▼          ▼           ▼            ▼              ▼
 Open WebUI   Gitea      Homepage     SearXNG      Plex, Proxmox,
     │       (+Postgres)                ▲         TrueNAS, UniFi…
     ├──▶ Ollama / llama.cpp            │
     └──────────── web search ──────────┘
```

- **One network.** Stacks join an external Docker network called `homelab`
  (created by `install.d/install-caddy.sh`). Containers can reach each other by
  name, e.g. Open WebUI → `http://searxng:8080`.
- **One certificate.** Every site is LAN-only, so Let's Encrypt can't reach it
  over HTTP. Caddy is custom-built with the Cloudflare DNS plugin and gets a
  single wildcard cert with a DNS-01 challenge. Adding a service just means a
  new `handle` block in the `Caddyfile` plus a LAN DNS record.
- **No secrets in git.** Each stack reads its config from a gitignored `.env`.
  A `.env.sample` / `.env.example` / `sample.env` template next to it shows
  which variables it needs. Some stacks pull their environment from 1Password
  instead (see [Secrets](#secrets)).

## Docker stacks

| Stack | Image | What it does |
|---|---|---|
| [`caddy`](docker/caddy) | custom (`caddy` + `caddy-dns/cloudflare`) | Reverse proxy and TLS for every service; ports 80/443 (+ HTTP/3) |
| [`gitea`](docker/gitea) | `gitea:1` + `postgres:17-alpine` | Self-hosted Git with LFS and a container registry; Postgres sits on an internal-only network |
| [`homepage`](docker/homepage) | `gethomepage/homepage` | Start-page dashboard with Proxmox, UniFi and service widgets |
| [`open-webui`](docker/open-webui) | `open-webui/open-webui` | Chat UI for local LLMs (Ollama and llama.cpp), with web search through SearXNG |
| [`searxng`](docker/searxng) | `searxng/searxng` | Private metasearch engine; also the web-search backend for Open WebUI and the MCP servers |
| [`mcp-searxng`](docker/mcp-searxng) | `isokoliuk/mcp-searxng` | MCP server that gives AI clients web search via SearXNG, behind Caddy with a bearer token |
| [`searxng-mcp-server`](docker/searxng-mcp-server) | built locally | Alternative SearXNG MCP server, bound to localhost only (no auth) |
| [`plex`](docker/plex) | `plexinc/pms-docker` | Media server on host networking; see [`MIGRATION.md`](docker/plex/MIGRATION.md) for moving hosts |
| [`nginx-proxy-manager`](docker/nginx-proxy-manager) | `jc21/nginx-proxy-manager` | Earlier GUI reverse proxy; uses the same 80/443 as Caddy, so run only one |
| [`openwebui`](docker/openwebui) | `open-webui` + `searxng` | Legacy combined stack, replaced by `open-webui` + `searxng` |

### Helper scripts in stack directories

| Script | Purpose |
|---|---|
| `*/op-docker-launch.sh <op-env-id>` | Run `docker compose up -d` with the stack's environment loaded from the given 1Password environment |
| `gitea/report.sh` | Status report for Gitea + Postgres: health, resources, versions, disk and DB size |
| `caddy/preflight.sh` | Check config before the first Caddy build, so problems don't burn Let's Encrypt rate limits on failed ACME challenges |
| `mcp-searxng/test-mcp.sh` | Smoke-test the MCP server: health, session, tool list, test search |
| `openwebui/install-searxng.sh` | One-time SearXNG setup for the legacy stack (enables JSON output, sets a secret key) |

## Host bootstrap — `install.d/`

| Script | Purpose |
|---|---|
| `install-docker.sh` | Install Docker via `get.docker.com` and add the current user to the `docker` group |
| `install-caddy.sh` | Bootstrap the Caddy stack and create the shared `homelab` network |
| `install-ollama.sh` | Install Ollama with Homebrew and run it as a service (macOS only) |
| `test-ollama.sh` | Check that Ollama's HTTP API is up |
| `deploy-module.sh` | `rsync` one `docker/<stack>` directory to the Docker host |

## Usage

**Deploy a stack** to the Docker host (default `docker01.snork.co`, into `/docker`):

```sh
install.d/deploy-module.sh <stack> [host]
# e.g.
install.d/deploy-module.sh open-webui
```

`README.md`, `.env`, `*.env` and `test*` files are excluded from the sync, so
real secrets never leave the machine they were created on. Create the `.env`
on the Docker host itself.

**Start it** on the Docker host:

```sh
cd /docker/<stack>
cp .env.sample .env    # or .env.example / sample.env — then fill it in
docker compose up -d
```

## Secrets

- Real `.env` files are gitignored; only templates are committed.
- Stacks with an `op-docker-launch.sh` load their environment from a
  [1Password environment](https://developer.1password.com/docs/cli/) with
  `op run`, authenticating as a service account. The service account token is
  read from `/etc/op/<env-id>.token` on the host and never stored in the repo.
- Compose files use `${VAR:?not set …}` for required values, so a missing
  secret stops the stack with a clear message instead of starting it half-configured.
