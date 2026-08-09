# agent-commons on d03

Migrated from k3s (2026-05-28). Corpus: **`/mnt/docker/agent-commons/`** (`agent_commons.db`).

## Run

```bash
# After update_scripts.sh syncs this tree to ~/scripts/d03/apps/agent-commons/
cp .env.example .env   # set AGENT_COMMONS_API_TOKEN if needed

# One-time: clone source for builds (or set AGENT_COMMONS_SRC to your checkout)
git clone https://gitea.asyla.org/asyla/agent-commons.git .src/agent-commons

~/scripts/d03/apps/agent-commons/agent-commons.sh up
~/scripts/d03/apps/agent-commons/agent-commons.sh verify
```

`up`, `restart`, and `refresh` **build the image for the host CPU** when the image is missing (`linux/amd64` on d03, `linux/arm64` on Apple Silicon). No manual `buildx --platform` flags.

| Command | Action |
|---------|--------|
| `build` | Build `AGENT_COMMONS_IMAGE` from source |
| `rebuild` | `build --no-cache` + recreate container |
| `update` | `git pull` in source dir + rebuild (or `compose pull` if `AGENT_COMMONS_PULL=1`) |
| `up` | ensure image + start |

## internal-proxy

Add **`agent_commons_net`** to internal-proxy compose and Caddy routes for `agent-commons.asyla.org` (web + `/mcp` → MCP port). Restart internal-proxy after changes.

## Registry (optional)

To pull a pinned image from Gitea instead of building:

```bash
docker login gitea.asyla.org
# In .env: AGENT_COMMONS_PULL=1 and AGENT_COMMONS_IMAGE=gitea.asyla.org/asyla/agent-commons:<tag>
```

## Edge

k3s `internal-proxy` Caddy forwards `agent-commons.asyla.org` to **10.0.0.62:8765/8766** until tunnel uses d03 Caddy directly.

## k3s

Production Deployment is scaled to **0**. Longhorn PVC retained; corpus copy on NAS: `agent-commons-migrate-20260528.tgz`.
