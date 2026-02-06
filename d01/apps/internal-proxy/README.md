# Internal reverse proxy (d01)

When **split DNS** (e.g. Pi-hole) points app hostnames to d01's IP (10.0.0.60), this Caddy container serves those hostnames on ports 80 and 443 and proxies to the apps.

- **TLS:** Let's Encrypt certificates via Cloudflare DNS-01. No private CA, no trusting certs on workstations—browsers accept the certs automatically.
- **Backend:** Configure in Caddyfile per hostname.

## First-time setup (one-time on d01)

1. **Create `.env`** with a Cloudflare API token that can edit DNS for asyla.org:
   ```bash
   cd ~/scripts/d01/apps/internal-proxy
   cp .env.example .env
   # Edit .env and set CF_API_TOKEN=your_token
   ```
   Create the token at [Cloudflare API Tokens](https://dash.cloudflare.com/profile/api-tokens): Custom token with **Zone → Zone: Read** and **Zone → DNS: Edit** (scope: asyla.org or your zone). You can reuse a token you already use for cloudflared/setup-tunnel-api if it has those permissions.

2. **Start the proxy.** Caddy will obtain Let's Encrypt certs for each hostname on first request and renew them automatically:
   ```bash
   ~/scripts/d01/apps/internal-proxy/internal-proxy.sh up
   ```

App hostnames (sonarr.asyla.org, etc.) must exist in Cloudflare DNS (they usually do for the tunnel). Caddy uses the DNS-01 challenge, so the server does not need to be reachable from the internet.

## Prerequisites

- Pi-hole (or your DNS) has records for app hostnames → d01's IP (10.0.0.60).
- Ports 80 and 443 on d01 are free.
- asyla.org (or your domain) is on Cloudflare so Caddy can do DNS-01.

## Run

```bash
~/scripts/d01/apps/internal-proxy/internal-proxy.sh up
```

Same management: `internal-proxy.sh down|restart|logs|pull`. Networks are created automatically.

## Add hostnames

Edit `Caddyfile` and add a block (hostname, `import internal_tls`, `reverse_proxy` to the app). Ensure the hostname has a DNS record in Cloudflare (can point anywhere for the challenge). Restart:

```bash
~/scripts/d01/apps/internal-proxy/internal-proxy.sh restart
```

## Optional: private CA (no Cloudflare API)

If you prefer not to use a Cloudflare API token, you can use a private CA and trust it on each workstation:

1. Run `./gen-certs.sh` to generate `certs/` (CA + server cert).
2. In `docker-compose.yml`, switch the image back to `caddy:latest`, add the volume `./certs:/etc/caddy/certs:ro`, and in `Caddyfile` replace the `(internal_tls)` snippet with:
   `tls /etc/caddy/certs/fullchain.pem /etc/caddy/certs/key.pem`
3. Trust `certs/ca.crt` on each workstation (Keychain / Trusted Root).
4. Remove `env_file: .env` and the `CF_API_TOKEN` env.

## Deploy/update

Run `~/update_scripts.sh` on d01 to pull the latest from the repo.
