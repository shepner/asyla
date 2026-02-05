# Homebridge on d01

Homebridge runs on d01 with **host network** (required for mDNS/HomeKit discovery). The web UI is exposed via a small proxy container so the cloudflared tunnel and internal proxy can reach it. Access is protected by **Cloudflare Access**.

- **URLs:** `https://homebridge.asyla.org` and `https://cameraui.asyla.org` both serve Camera UI (port 8181). The main Homebridge UI (8581) redirects to /camview, so both hostnames use 8181 for consistent behavior.
- **Image:** [homebridge/homebridge](https://github.com/homebridge/homebridge/wiki/Install-Homebridge-on-Docker) (official; migrated from oznu/homebridge)
- **Storage:** `${DOCKER_DL}/homebridge` → `/homebridge` in container (config, plugins, etc.)

## Commands

```bash
~/scripts/d01/apps/homebridge/homebridge.sh up    # start
~/scripts/d01/apps/homebridge/homebridge.sh down # stop
~/scripts/d01/apps/homebridge/homebridge.sh logs  # follow logs
~/scripts/d01/apps/homebridge/homebridge.sh pull  # pull image and up
```

## First-time setup

1. Ensure **cloudflared** and **internal-proxy** are running (they attach to `homebridge_net`). Start homebridge so the proxy is on `homebridge_net`.
2. Run `homebridge.sh up`.
3. Run **setup-tunnel-api.py** in the cloudflared app dir so `homebridge.asyla.org` gets tunnel ingress, DNS, and Cloudflare Access.
4. Restart cloudflared if it was already running when you added the app.

## Migration from original

The original `docker/homebridge.sh` used:
- **Image:** oznu/homebridge:latest (replaced with homebridge/homebridge:latest)
- **Volume:** `${DOCKER_DL}/homebridge` → `/homebridge` (same: whole app dir)
- **Network:** host (same; required for Avahi/mDNS and HomeKit)
- **Env:** TZ, ENABLE_AVAHI=1 (same)

Ports on the host: 8581 (main Homebridge UI; redirects to /camview), 8181 (Camera UI; used for both hostnames), 51956 (Homebridge HAP service). homebridge-proxy (8581) and cameraui-proxy (8181) expose the UIs; HomeKit discovery remains on the host network.
