# agent-commons on d03

Migrated from k3s (2026-05-28). Corpus: **`/mnt/docker/agent-commons/`** (`agent_commons.db`).

## Run

```bash
# After update_scripts.sh syncs this tree to ~/scripts/d03/apps/agent-commons/
cp .env.example .env   # set AGENT_COMMONS_API_TOKEN if needed
~/scripts/d03/apps/agent-commons/agent-commons.sh up
~/scripts/d03/apps/agent-commons/agent-commons.sh verify
```

## internal-proxy

Add **`agent_commons_net`** to internal-proxy compose and Caddy routes for `agent-commons.asyla.org` (web + `/mcp` → MCP port). Restart internal-proxy after changes.

## Registry

```bash
docker login gitea.asyla.org
```

## k3s

Production Deployment is scaled to **0**. Longhorn PVC retained; corpus copy on NAS: `agent-commons-migrate-20260528.tgz`.
