# d01

Docker host VM (Debian 13, cloud-init) on Proxmox vmh01 at **10.0.0.60**, VMID **101**.

Built from the same pattern as d02: Debian cloud image, cloud-init, Docker, NFS/SMB clients, cloudflared tunnel, and internal Caddy proxy. Application data lives on a local SSD-backed disk (Proxmox `local-data2`) mounted at `/mnt/docker` — formerly served via iSCSI from the NAS, migrated 2026-05-21 to remove iSCSI fragility.

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
5. **Cloudflared:** `cd ~/scripts/d01/apps/cloudflared && cp .env.example .env` (set `TUNNEL_TOKEN` or `TUNNEL_ID`), then `~/scripts/d01/apps/cloudflared/cloudflared.sh up`
6. **Internal proxy:** `~/scripts/d01/apps/internal-proxy/internal-proxy.sh up`
7. SMB credentials: `~/setup_manual.sh`

**Note:** All app scripts (`media.sh up`, `cloudflared.sh up`, `internal-proxy.sh up`) create required networks automatically.

## Layout

- `build.sh` – Destroy/create VM 101 on vmh01, import Debian cloud image, cloud-init, verify.
- `setup/` – cloud-init userdata/vendor, bootstrap, deploy_software, systemConfig, nfs, smb, docker, setup_manual, setup_ssh_keys, etc.
- `apps/cloudflared/` – Cloudflare Tunnel (cloudflared.sh, compose, apps.yml, setup-tunnel-api.py).
- `apps/internal-proxy/` – Caddy reverse proxy for split-DNS (internal-proxy.sh, Caddyfile).
- `apps/media/` – Media stack: Sonarr, Radarr, Overseerr, Jackett, Transmission (media.sh); access via cloudflared/internal proxy.
- `update_scripts.sh`, `update.sh`, `update_all.sh` – Script update and OS maintenance.

## Application storage (`/mnt/docker`)

`/mnt/docker` is a local SSD-backed disk attached to VM 101 via Proxmox's `local-data2` LVM-thin pool on vmh01 (UUID fixed in `/etc/fstab`, ext4, mounted with `discard,nofail`). Sized 128 GiB for d01's footprint; resize the LVM-thin volume on vmh01 (`lvextend`) plus the in-VM partition + filesystem (`growpart` + `resize2fs`) if more space is needed.

Historical note: d01 originally ran with `/mnt/docker` served via iSCSI from TrueNAS (`nas01:d01:01`). That setup was migrated to local SSD on 2026-05-21 to remove iSCSI session/boot-ordering fragility (Debian Trixie bug #1090725) and to free the NAS for backup duty only. The iSCSI target and initiator config on TrueNAS can be removed once you're confident the migration is stable.
