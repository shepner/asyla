# d01

Docker host VM (Debian 13, cloud-init) on Proxmox vmh01 at **10.0.0.60**, VMID **101**.

Built from the same pattern as d02/d03: Debian cloud image, cloud-init, Docker, NFS/SMB/iSCSI clients, cloudflared tunnel, and internal Caddy proxy.

## Build (from workstation)

```bash
cd /path/to/asyla
./d01/build.sh
```

Requires:

- SSH to `root@vmh01`
- `d01` in `~/.ssh/config` (HostName 10.0.0.60, User docker)
- `~/.ssh/docker_rsa.pub` for cloud-init

## After first boot

1. SSH: `ssh d01`
2. Copy SSH keys and config from workstation (see build.sh next steps).
3. Run: `~/scripts/d01/setup/setup_ssh_keys.sh`
4. **Media stack:** `~/scripts/d01/apps/media/media.sh up` (sources common.env automatically)
5. **Cloudflared:** `cd ~/scripts/d01/cloudflared && cp .env.example .env` (set `TUNNEL_TOKEN` or `TUNNEL_ID`), then `./start.sh`
6. **Internal proxy:** `cd ~/scripts/d01/internal-proxy && ./start.sh`
7. SMB + iSCSI: `~/setup_manual.sh` (after adding initiator to TrueNAS for iSCSI target `nas01:d01:01`)

**Note:** All start scripts (`media.sh up`, `cloudflared/start.sh`, `internal-proxy/start.sh`) create required networks automatically.

## Layout

- `build.sh` – Destroy/create VM 101 on vmh01, import Debian cloud image, cloud-init, verify.
- `setup/` – cloud-init userdata/vendor, bootstrap, deploy_software, systemConfig, nfs, smb, iscsi, docker, setup_manual, setup_ssh_keys, etc.
- `cloudflared/` – Cloudflare Tunnel (docker-compose, apps.yml, .env.example).
- `internal-proxy/` – Caddy reverse proxy for split-DNS (same hostnames, internal traffic).
- `apps/media/` – Media stack: Sonarr, Radarr, Overseerr, Jackett, Transmission (compose + media.sh); access via cloudflared/internal proxy.
- `docker-compose.yml` – Defines networks (d01_internet, d01_internal, d01_backend); add services as apps are deployed.
- `update_scripts.sh`, `update.sh`, `update_all.sh` – Script update and OS maintenance.

## iSCSI

Target name for d01 on TrueNAS: `iqn.2005-10.org.freenas.ctl:nas01:d01:01`. Add this host's initiator to the target's Initiator Group before running `~/setup_manual.sh` (iSCSI step) or `~/scripts/d01/setup/setup_iscsi_connect.sh`.
