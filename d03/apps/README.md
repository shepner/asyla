# d03 apps

All d03 apps use the same management pattern: a script accepting **up**, **down**, **restart**,
**backup**, **update**, **refresh**, and **logs**. `~/update_all.sh` discovers every directory
under `~/scripts/d03/apps/` and runs `backup` then `update` on each.

## Owned by this repo

Deployed by `update_scripts.sh`, which copies `d03/` into `~/scripts/d03/`.

| App | Script | Notes |
|-----|--------|-------|
| **gitea** | `~/scripts/d03/apps/gitea/gitea.sh` | Git server, internal only (gitea.asyla.org via internal-access). `USER_UID`/`USER_GID` are both 1003 to match the migrated data volume |
| **agent-commons** | `~/scripts/d03/apps/agent-commons/agent-commons.sh` | Problem/answer corpus; image pulled from the Gitea registry, overridable via `.env` `AGENT_COMMONS_IMAGE` |
| **breeding-research** | `~/scripts/d03/apps/breeding-research/breeding-research.sh` | Scraper + API; needs `.env` |
| **tc-datalogger** | `~/scripts/d03/apps/tc-datalogger/tc-datalogger.sh` | Torn City API → BigQuery stack; needs `.env` |

## Owned elsewhere — do not add them here

The edge stack lives in its own repos under `asyla/projects/` and is deployed straight to the
host with `scripts/deploy-host.sh d03` (`rsync --delete`). It lands in the same `apps/` directory
and `update_all.sh` maintains it alongside the rest, but this repo must **not** carry a copy —
two masters writing the same path is how the May 2026 drift happened.

| App | Source repo | Notes |
|-----|-------------|-------|
| **external-access** | `asyla/projects/external-access` | Cloudflare Tunnel; per-host config in `hosts/d03/`; needs `host.env` |
| **internal-access** | `asyla/projects/internal-access` | Caddy for split-DNS on ports 80/443; needs `host.env` with `CF_API_TOKEN` |

To add a tunnel hostname, edit `hosts/d03/apps.yml` in `asyla/projects/external-access` and run
`external-access.sh genconfig`. The old `d03/scripts/add-tunnel-app.sh` was removed: it wrote a
YAML schema the current generator does not accept.

## Start order

The proxy needs every app network to exist first, so start the apps before the edge.

```bash
~/scripts/d03/apps/gitea/gitea.sh up
~/scripts/d03/apps/agent-commons/agent-commons.sh up
~/scripts/d03/apps/breeding-research/breeding-research.sh up
~/scripts/d03/apps/tc-datalogger/tc-datalogger.sh up
~/scripts/d03/apps/internal-access/internal-access.sh up
~/scripts/d03/apps/external-access/external-access.sh up
```
