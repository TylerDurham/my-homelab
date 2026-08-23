# Caddy with the Cloudflare DNS plugin compiled in.
#
# The official caddy image ships no DNS provider modules, and LAN-only sites
# can't answer an HTTP-01 challenge (Let's Encrypt can't reach them), so the
# certs here are issued over DNS-01. That requires a custom build.
ARG CADDY_VERSION=2.11.4

FROM caddy:${CADDY_VERSION}-builder AS builder
RUN xcaddy build --with github.com/caddy-dns/cloudflare

FROM caddy:${CADDY_VERSION}
COPY --from=builder /usr/bin/caddy /usr/bin/caddy
