# TrueNAS MCP on d03

[TrueNAS Core MCP Server](https://github.com/vespo92/TrueNasCoreMCP) — control TrueNAS from Cursor/Claude via the Model Context Protocol. Installation guide: [INSTALL.md](https://github.com/vespo92/TrueNasCoreMCP/blob/main/docs/guides/INSTALL.md).

**Internal only — never internet-accessible.** This app must only be used internally (e.g. via the internal proxy if/when HTTP is used, or via stdio from internal clients). **Do not add a Cloudflare Tunnel public hostname for truenas-mcp.**

## Layout on d03

- **App dir**: `~/scripts/d03/apps/truenas-mcp/` (or asyla repo `d03/apps/truenas-mcp/`)
- **Config**: `.env` in the app dir with `TRUENAS_URL` and `TRUENAS_API_KEY` (copy from `.env.example`)

## One-time setup (on d03)

1. **Get TrueNAS API key**
   - Log into TrueNAS Web UI → **Settings → API Keys** → **Add**
   - Copy the key (it is shown only once).

2. **Create `.env`**
   ```bash
   cd ~/scripts/d03/apps/truenas-mcp
   cp .env.example .env
   # Edit .env: set TRUENAS_URL and TRUENAS_API_KEY
   ```

3. **Build image (optional, or on first up)**
   ```bash
   ~/scripts/d03/apps/truenas-mcp/truenas-mcp.sh up
   ```

## Commands (on d03)

| Command | Action |
|--------|--------|
| `truenas-mcp.sh up` | Build (if needed) and start container |
| `truenas-mcp.sh down` | Stop and remove containers |
| `truenas-mcp.sh restart` | Down then up |
| `truenas-mcp.sh refresh` | Rebuild (no cache) and start |
| `truenas-mcp.sh update` | Rebuild (pull base) and start |
| `truenas-mcp.sh run` | Run server with stdio (for Cursor/Claude; not detached) |
| `truenas-mcp.sh logs [service]` | Follow logs |

Run from the app script path, e.g.:

```bash
~/scripts/d03/apps/truenas-mcp/truenas-mcp.sh up
~/scripts/d03/apps/truenas-mcp/truenas-mcp.sh run
```

Optional symlink:

```bash
ln -sf ~/scripts/d03/apps/truenas-mcp/truenas-mcp.sh ~/truenas-mcp.sh
~/truenas-mcp.sh run
```

## Internal access only

- **Do not** add truenas-mcp to the Cloudflare Tunnel (no public hostname in Zero Trust).
- Access is internal only: run the server via `truenas-mcp.sh run` (or the container) from machines on the internal network; if the server gains HTTP/SSE in the future, it would be exposed only via the internal proxy (Caddy), not the tunnel.

## Using with Cursor / Claude Desktop

The server uses **stdio** transport. To attach Cursor or Claude Desktop:

1. **Option A — run on d03 and connect from workstation**  
   On d03, run the server in the foreground (or via a process manager that keeps it running with stdio). Configure Cursor/Claude to connect over SSH (e.g. remote MCP over SSH to d03) if your client supports it.

2. **Option B — run container from workstation**  
   Copy this app (or the same env) to your workstation and run:
   ```bash
   cd /path/to/d03/apps/truenas-mcp
   docker compose run --rm truenas-mcp
   ```
   Then in Cursor MCP settings, set the server command to that `docker compose run` line (with env from `.env`).

3. **Cursor MCP config (when server runs as subprocess)**  
   If Cursor runs the server as a subprocess, point it at the script that runs the container with stdio, e.g.:
   ```json
   "truenas": {
     "command": "/path/to/truenas-mcp.sh",
     "args": ["run"],
     "env": {
       "TRUENAS_URL": "https://your-truenas.local",
       "TRUENAS_API_KEY": "your-api-key"
     }
   }
   ```
   (Or use `docker compose run --rm truenas-mcp` with the same env.)

## Optional env vars

| Variable | Default | Description |
|----------|---------|-------------|
| `TRUENAS_VERIFY_SSL` | `true` | Set `false` for self-signed certs (dev/internal only) |
| `TRUENAS_LOG_LEVEL` | `INFO` | Log level |
| `TRUENAS_HTTP_TIMEOUT` | — | Timeout in seconds |

## Troubleshooting

- **SSL errors**: Set `TRUENAS_VERIFY_SSL=false` in `.env` only on trusted networks.
- **Permission denied**: Ensure the API key has the needed TrueNAS permissions.
- **Connection timeout**: Check `TRUENAS_URL` is reachable from d03 (e.g. `curl "$TRUENAS_URL"`).

## References

- [TrueNasCoreMCP](https://github.com/vespo92/TrueNasCoreMCP) — source and docs
- [Installation guide](https://github.com/vespo92/TrueNasCoreMCP/blob/main/docs/guides/INSTALL.md)
