# Calibre on d01

Calibre e-book manager runs on d01 and is reachable via the cloudflared tunnel and internal proxy. Access is protected by **Cloudflare Access** (same as Sonarr, Radarr, etc.).

- **URL:** `https://calibre.asyla.org` (after tunnel + DNS + Access are configured)
- **Image:** [linuxserver/calibre](https://docs.linuxserver.io/images/docker-calibre)
- **Network:** `media_net` (no host ports; proxy only)

## Commands

```bash
~/scripts/d01/apps/calibre/calibre.sh up    # start
~/scripts/d01/apps/calibre/calibre.sh down  # stop
~/scripts/d01/apps/calibre/calibre.sh logs  # follow logs
~/scripts/d01/apps/calibre/calibre.sh pull  # pull image and up
```

## First-time setup

1. Ensure **media**, **cloudflared**, and **internal-proxy** are running (so `media_net` exists).
2. Run `calibre.sh up`.
3. Run **setup-tunnel-api.py** (with your Cloudflare API token) so `calibre.asyla.org` gets tunnel ingress, DNS, and a Cloudflare Access application.
4. Restart cloudflared if you run it after adding the new app.

In the Calibre GUI, use the default library path `/config/Calibre Library`. To enable the built-in webserver, use Calibre Preferences → Sharing over the net (port 8081); the main access remains via the desktop GUI at port 8080 through the proxy.
