# Plex Docker Migration Notes

## What to Copy

| Item | Action |
|------|--------|
| `docker/plex/` (compose + `.env`) | Copy — already portable |
| `./config/` | **Must copy** — contains Plex database, metadata, library settings |
| Media files (`MEDIA_PATH`) | Copy, or re-point `MEDIA_PATH` in `.env` if media is on shared storage |
| `./transcode/` | Skip — ephemeral, Plex rebuilds it |

## PLEX_CLAIM Token

Only used for initial server registration. If migrating an existing `config/` directory, Plex already knows its identity — the token is ignored. A fresh claim token is only needed when starting from scratch.

## Migration Steps

1. Stop Plex on the old server
2. Rsync the config directory to the new server
3. Update `MEDIA_PATH` in `.env` if the path changes
4. Start Plex on the new server

```bash
rsync -av --progress user@old-server:/path/to/docker/plex/config/ /path/to/docker/plex/config/
```

> Drop `-z` (compression) on a local LAN — at 10GbE it adds CPU overhead with no benefit.
> Stop Plex before rsyncing — the SQLite databases will corrupt if copied while open.

## Notes

- Config directory size: ~5.5GB
- Link speed: 10GbE — expect transfer in under a minute
- rsync uses SSH by default and will pick up `~/.ssh` keys automatically
