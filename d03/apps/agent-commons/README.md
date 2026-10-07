# agent-commons on d03

Migrated from k3s (2026-05-28). Corpus: **`/mnt/docker/agent-commons/`** (`agent_commons.db`).
Source: Gitea `asyla/agent-commons`. The image is built on d03; there is no registry image and no
source checkout on the host.

## Run

```bash
# After update_scripts.sh syncs this tree to ~/scripts/d03/apps/agent-commons/
cp .env.example .env   # set AGENT_COMMONS_API_TOKEN if needed
~/scripts/d03/apps/agent-commons/agent-commons.sh up
~/scripts/d03/apps/agent-commons/agent-commons.sh verify
```

`verify` checks that the container runs the configured image, that `/api/v1/health` reports that
image's `app_version`, and that MCP on :8766 answers `initialize`.

## Deployed revision

The `image:` default in [compose.yml](compose.yml) is the deployed revision (`agent-commons:<sha7>`),
so its git history is the deployment record. The host `.env` must not set `AGENT_COMMONS_IMAGE`
except during a rollback.

## How to deploy a new ref

Push the ref to Gitea `asyla/agent-commons` first. Then, on d03, run
`agent-commons.sh build <ref>`: it builds `agent-commons:<sha7>` with
`AGENT_COMMONS_APP_VERSION=<sha7>` from a `git archive` of the bare repo inside the `gitea` container.
Next run `agent-commons.sh rehearse <ref>`, which copies the live DB with SQLite's backup API, serves
the copy from the new image on 127.0.0.1:18765/18766, checks health, version, MCP `initialize`,
search and the log, then removes the container and the copy. If the rehearsal passes, set the
`compose.yml` default to `agent-commons:<sha7>`, commit and push this repo (`master`), and run
`~/update_scripts.sh` on d03. With the operator's go-ahead for the restart, run
`agent-commons.sh down _backup up verify`. A security rebuild of the deployed ref is
`build` (no ref) followed by the same `rehearse` and `down _backup up verify`. The image it replaces
is kept as `agent-commons:<sha7>-prev`.

## Rollback

Set `AGENT_COMMONS_IMAGE=<previous tag>` in `.env` (any local `agent-commons:` tag; `docker images
agent-commons`), then run `agent-commons.sh down up verify`. Afterwards, revert the pin in
`compose.yml` and delete the `.env` line.

## Switches for host maintenance

`update` only builds the configured image if it is missing, and `refresh` is `update` followed by
`up`. Neither pulls. `update_all.sh` runs `backup` and `update`, so it never restarts the service.
host-maintenance has `update = "never"` for this app.

## internal-proxy

Add **`agent_commons_net`** to internal-proxy compose and Caddy routes for `agent-commons.asyla.org` (web + `/mcp` → MCP port). Restart internal-proxy after changes.

## k3s

Production Deployment is scaled to **0**. Longhorn PVC retained; corpus copy on NAS: `agent-commons-migrate-20260528.tgz`.
