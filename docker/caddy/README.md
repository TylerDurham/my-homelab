# Caddy — HTTPS for the homelab

Terminates TLS for every homelab site with publicly-trusted Let's Encrypt certs,
while the sites themselves stay on the LAN.

## Why DNS-01

The sites resolve to private IPs, so Let's Encrypt can't reach them to run the
usual HTTP-01 challenge. Instead Caddy proves domain ownership by writing a TXT
record into the zone through Cloudflare's API. Nothing is exposed to the
internet, and browsers still get a green padlock — no private CA, no root cert
to install on every device.

DNS-01 is also the only challenge type that can issue a **wildcard**, which is
what this setup uses: one `*.snork.co` certificate covers every service, so
adding one later is a Caddyfile edit and a LAN DNS record — no new certificate
and no ACME round trip.

The official `caddy` image ships no DNS plugins, so `Dockerfile` rebuilds Caddy
with `github.com/caddy-dns/cloudflare` compiled in.

## Why Cloudflare and not the registrar's DNS

The domain is registered at GoDaddy; only DNS is delegated to Cloudflare. This
is deliberate:

- **GoDaddy** gates its DNS API by account size. In April 2024 they cut off
  anyone with fewer than 10 domains, breaking cert renewal for a lot of people
  overnight; they relaxed it to 1+ domain in April 2026. More pressingly,
  `libdns/godaddy` authenticates with `sso-key` against the v1 API, which
  GoDaddy's own docs mark *"Deprecated (supported through 2026)"* — and that
  library hasn't been updated since November 2025.
- **Hostinger** has exactly one Caddy module, a third-party repo with 9 commits
  and no other users.
- **Cloudflare** is the most-used DNS plugin in the Caddy ecosystem (~985 stars,
  actively maintained), free, and its tokens scope to a single zone.

Registrar and DNS host don't have to be the same company, and keeping them
separate means switching registrars later never touches this setup.

## Hostnames

With `CADDY_DOMAIN=snork.co`:

| URL | Upstream |
|-----|----------|
| `https://home.snork.co` | homepage:3000 |
| `https://chat.snork.co` | open-webui:8080 |
| `https://search.snork.co` | searxng:8080 |
| `https://plex.snork.co` | `${PLEX_HOST}`:32400 |

Anything else under `*.snork.co` is covered by the cert but returns a 404 from
Caddy until it gets a `handle` block.

### Adding a service

1. Add a `handle` block to the `Caddyfile`, matching the existing pattern:

   ```
   @grafana host grafana.{$CADDY_DOMAIN}
   handle @grafana {
       import secure_headers
       reverse_proxy grafana:3000
   }
   ```

2. Put the service on the `homelab` network and drop its published ports.
3. Make sure LAN DNS resolves the hostname (a wildcard record covers it — see
   step 5 below).
4. `docker compose exec caddy caddy reload --config /etc/caddy/Caddyfile`

No certificate work: the wildcard already covers it.

## Setup

### 1. Point the domain at Cloudflare

Do this while the domain is still empty — it's much easier than migrating later.

1. Add the domain as a zone at [dash.cloudflare.com](https://dash.cloudflare.com)
   (Free plan is fine). Cloudflare will assign two nameservers.
2. At GoDaddy: **My Products → Domain → DNS → Nameservers → Change → I'll use my
   own nameservers**, and enter the two Cloudflare gave you.
3. Wait for Cloudflare to mark the zone **Active**. Usually minutes, but
   registrar nameserver changes can take a few hours to propagate.

GoDaddy remains the registrar and still handles renewal — only DNS moves.

### 2. Cloudflare API token

Create at [dash.cloudflare.com/profile/api-tokens](https://dash.cloudflare.com/profile/api-tokens)
→ **Create Custom Token**, with:

- `Zone` : `Zone` : `Read`
- `Zone` : `DNS` : `Edit`

Scope it to **this zone only** under Zone Resources — not "All zones". Then:

```bash
cp .env.example .env
$EDITOR .env        # set CF_API_TOKEN and PLEX_HOST
```

### 3. Shared docker network

All stacks talk to Caddy over one user-defined network, so it can proxy by
container name and the individual services no longer publish ports to the LAN.

```bash
docker network create homelab
```

### 4. Preflight, then build and start

Check delegation and token scopes before issuing anything — a failed ACME
challenge still counts against Let's Encrypt's rate limit:

```bash
./preflight.sh
```

It verifies the zone is delegated to Cloudflare, the token is valid, and the
token can read and edit DNS for the zone. Re-run it while nameservers
propagate; it's safe to run repeatedly. Then:

```bash
../../install.d/install-caddy.sh
```

Or by hand:

```bash
docker compose build     # compiles Caddy + plugin, takes a minute
docker compose up -d
docker compose logs -f caddy
```

First start issues one certificate, for `*.snork.co`. Watch for `certificate
obtained successfully`. Caddy issues it lazily on the first request to any
matching hostname, so if the log looks idle, load one of the sites.

### 5. Point the LAN at Caddy

Certs come from public DNS, but *resolution* has to happen locally — this is the
split-horizon half. On the UniFi Cloud Gateway:

**Settings → Routing → DNS → Local DNS Records** — add a single wildcard A
record, `*.snork.co`, pointing at the Docker host's LAN IP. That covers every
current and future subhost in one entry.

If your UniFi version doesn't support wildcard local records, add one A record
per hostname instead, and remember to add another each time you add a service.

Give the Docker host a fixed IP first (Settings → Client Devices → Fixed IP),
otherwise DHCP will eventually move it and every record breaks.

Clients must use the gateway as their DNS server for these to resolve — that's
the default unless you've overridden DNS on the network.

> Leave the records **out** of Cloudflare, or set them to "DNS only" (grey
> cloud) if you add them. Proxied (orange cloud) records point at Cloudflare's
> edge, which cannot reach a private IP.

### 6. Restart the other stacks

They need to join the network and learn their new hostnames:

```bash
cd ../homepage   && cp .env.example .env && docker compose up -d
cd ../openwebui  && $EDITOR .env  # set OLLAMA_BASE_URL
                    docker compose up -d
```

## Notes

**The bare apex.** `*.snork.co` does *not* cover `snork.co` itself — that's how
wildcard certs work, one label only. Nothing is bound to the apex here, which
leaves it free for a public site later. To make a bare `snork.co` redirect to
the dashboard, it needs its own site block (and therefore its own certificate)
plus its own LAN DNS record:

```
{$CADDY_DOMAIN} {
	import tls_dns
	redir https://home.{$CADDY_DOMAIN}{uri}
}
```

**Cert storage.** The `caddy_data` volume holds certificates *and* the ACME
account key. Don't delete it casually — Let's Encrypt rate-limits to 5
duplicate certs per week, which is easy to burn through while debugging.

**Plex.** It runs `network_mode: host` on a separate machine (`10.0.0.7`, a
different subnet from the Caddy host), so it's reached by IP rather than
container name and never joins the `homelab` network — hence `PLEX_HOST` in
`.env`. The gateway routes between the two subnets; if that ever stops being
true, this is the proxy entry that breaks first. Note that Plex already
serves working TLS via its own `*.plex.direct` certs, so proxying it is mostly
about having one consistent naming scheme. Apps like Plexamp sometimes prefer
the direct address. If you proxy it, add the URL under
**Settings → Network → Custom server access URLs** in Plex.

**Homepage.** `HOMEPAGE_ALLOWED_HOSTS` must match the hostname Caddy serves it
on (`home.snork.co`), or it returns a host-check error. It was previously set to
the upstream project's placeholder (`gethomepage.dev`), which would have
rejected requests.

**Staging first.** To avoid rate limits while testing, add this to the global
block in the `Caddyfile`, then remove it once issuance works:

```
acme_ca https://acme-staging-v02.api.letsencrypt.org/directory
```

Staging certs are untrusted — expect a browser warning; that's the point.
