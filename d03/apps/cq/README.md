# cq (Mozilla) — team knowledge API on d03

Deploys the [mozilla-ai/cq](https://github.com/mozilla-ai/cq) **team tier**: FastAPI + SQLite (`team.db`) and the React review UI. Agents on your laptops point the cq MCP server at this service (**team mode**) via split-DNS / internal TLS.

## One-time setup (on d03)

1. **Upstream + secrets**: First run of `cq.sh` clones [mozilla-ai/cq](https://github.com/mozilla-ai/cq) into `./upstream` (pinned tag `0.4.0` by default) and creates `.env` with **`CQ_JWT_SECRET`** if needed. That variable is only for the **team API server**: it signs JWTs for logged-in review UI sessions. It is **not** your UI login password, not for MCP clients, and you do not copy it to laptops. To pin a different release: `CQ_UPSTREAM_REF=main ./cq.sh refresh` (export or prefix once).

2. **DNS**: Add `cq.asyla.org` → d03 (Pi-hole / split-DNS), same pattern as `vikunja.asyla.org`.

3. **Proxy**: This repo’s `internal-proxy` Caddyfile includes `cq.asyla.org`. After first `cq.sh up`, restart the internal-proxy stack so Caddy joins `cq_net`:

   ```bash
   ~/scripts/d03/apps/internal-proxy/internal-proxy.sh restart
   ```

4. **Start cq**:

   ```bash
   ~/scripts/d03/apps/cq/cq.sh refresh
   ```

5. **Review UI login**: Create a user in the team DB (after the API has created `team.db` once):

   ```bash
   python3 upstream/scripts/seed-users.py \
     --db "${DOCKER_DL:-/mnt/docker}/cq/data/team.db" \
     --username YOUR_USER \
     --password 'YOUR_SECURE_PASSWORD'
   ```

   Requires `pip install bcrypt` (or run from a venv that has it). Use the UI at `https://cq.asyla.org` to log in and approve pending knowledge units.

## Agent / MCP clients (team mode)

- **`CQ_TEAM_ADDR`**: `https://cq.asyla.org/api` — the team UI’s nginx proxies `/api/*` to the API, so MCP `httpx` `GET /query` becomes `https://cq.asyla.org/api/query`.
- **`CQ_TEAM_API_KEY`**: In current cq PoC, core `/query` and `/propose` paths are **not** JWT-gated; the README still mentions an API key for forward compatibility. If your client sends a Bearer token, align with whatever cq release you run.

Local-only mode omits `CQ_TEAM_*` and uses `~/.cq/local.db` on each machine.

## “Each project has its own identity” — how cq models that

cq’s PoC is **one team store per deployment**, not multi-tenant isolation. **Project identity is convention + `domain` tags** on each knowledge unit (e.g. `domain=memory-system`, `domain=gitea`, `domain=asyla`). Queries pass multiple domains; the API returns matching approved units ([team API `GET /query`](https://github.com/mozilla-ai/cq/blob/main/team-api/team_api/app.py)).

So: **team mode = shared commons for your estate**; **per-repo separation = tag discipline** (and optional extra cq stacks only if you truly need hard isolation).

## Data and backups

- SQLite: `${DOCKER_DL}/cq/data/team.db` (and WAL files). Include in your existing Docker volume backup practice.

## Troubleshooting

**`cq-team-api` restarts in a loop** — almost always **permissions on the bind-mounted data dir**. The stack defaults to **uid/gid 1000:1000** (`CQ_TEAM_API_UID` / `CQ_TEAM_API_GID` in `.env` and compose `user:`). On `up` / `refresh` / `restart`, `cq.sh` `mkdir -p`s and `chown`s `${DOCKER_DL}/cq/data` to match (may use **sudo** once if root created the tree). Override in `.env` if your host uses different ids. Check `docker logs cq-team-api`.

## Scripts on d03

Synced from this repo to `~/scripts/d03/apps/cq/` via your usual `update_scripts.sh` flow.
