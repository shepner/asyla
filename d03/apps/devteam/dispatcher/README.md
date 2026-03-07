# Dispatcher (knowledge-hub dispatch agent on d03)

Runs the Cursor-based dispatcher pipeline in a container on d03. The image is built from the **knowledge-hub** checkout at `~/scripts/knowledge-hub`; this directory holds the Compose file, env template, and `dispatcher.sh`.

**Artefacts:** asyla/d03/apps/devteam/dispatcher (this directory).

## Prerequisites on d03

- knowledge-hub cloned at `~/scripts/knowledge-hub` (so build context `../../../../../knowledge-hub` from this dir resolves).
- OpenBao running and Cursor API key stored (see devteam `deploy-devteam.sh`).
- `.config/env` populated from `.config/env.example` with `OPENBAO_ADDR` and `OPENBAO_TOKEN` (or `OPENBAO_TOKEN_FILE`).

## One-time setup

```bash
cd ~/scripts/d03/apps/devteam/dispatcher
cp .config/env.example .config/env
# Edit .config/env: set OPENBAO_TOKEN (or OPENBAO_TOKEN_FILE)
```

## Operator commands (`dispatcher.sh`)

Run from anywhere; script uses its own directory for compose and project-dir.

| Command      | Description |
|-------------|-------------|
| `up`        | Start dispatcher container (daemon; `restart: unless-stopped`) |
| `down`      | Stop and remove container |
| `one-cycle` | Run one poll cycle and exit — **testable**: container starts and runs one cycle |
| `logs`      | Follow container logs |

Examples:

```bash
cd ~/scripts/d03/apps/devteam/dispatcher
./dispatcher.sh up
./dispatcher.sh one-cycle   # smoke test: one cycle then exit
./dispatcher.sh logs
./dispatcher.sh down
```

## Testable: container starts and runs one cycle

Acceptance criterion: container starts and runs one dispatch cycle. To verify:

```bash
cd ~/scripts/d03/apps/devteam/dispatcher
./dispatcher.sh one-cycle
```

This runs the dispatcher with `--poll --poll-interval 0` (single cycle then exit). Exit code 0 and log output indicate success. No daemon is left running.

## Configuration

- **Secrets**: `CURSOR_API_KEY` and `OPENBAO_TOKEN` are sourced from `.config/env` (never hardcoded). The container fetches the Cursor API key from OpenBao at startup.
- **_runs**: Mounted from `~/scripts/knowledge-hub/_runs` so run logs persist on the host.
- **Restart**: `restart: unless-stopped` so the container comes back after reboot.

## Alternative: raw docker compose

If you prefer not to use the script:

```bash
cd ~/scripts/d03/apps/devteam/dispatcher
docker compose up -d
docker compose run --rm dispatcher python3 .cursor/helpers/dispatch_agent.py --poll --poll-interval 0 --project /app  # one cycle
docker compose logs -f
docker compose down
```
