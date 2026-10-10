# d01

Docker host VM (Debian 13, cloud-init) on Proxmox vmh01 at **10.0.0.60**, VMID **101**.

Built from the same pattern as d02: Debian cloud image, cloud-init, Docker, NFS/SMB clients, cloudflared tunnel, and internal Caddy proxy. Application data lives on a local SSD-backed disk (Proxmox `local-data2`) mounted at `/mnt/docker` — formerly served via iSCSI from the NAS, migrated 2026-05-21 to remove iSCSI fragility.

## Build (from workstation)

```bash
scripts/build_host.py d01 plan      # read-only: spec, live VM, gaps
scripts/build_host.py d01 build     # dry run of every phase; add --apply to act
scripts/build_host.py d01 verify    # read-only
```

The spec is `d01/host.toml`. Rebuilding the existing VM needs `--recreate --confirm d01`. The old
`d01/build.sh` was removed on 2026-10-10: it ran `qm destroy 101 --purge` with no confirmation, on
vmh01 (the spec has d01 on vmh02).

Requires:

- SSH to the hypervisor as root (the node in `d01/host.toml`)
- `d01` in `~/.ssh/config` (HostName 10.0.0.60, User docker)
- `~/.ssh/docker_rsa.pub` for cloud-init

## After first boot

1. SSH: `ssh d01`
2. Copy SSH keys and config from workstation (`~/.ssh/docker_rsa`, `~/.ssh/config`; mode 600, `~/.ssh` 700).
3. Run: `~/scripts/d01/setup/setup_ssh_keys.sh`
4. **Media stack:** `~/scripts/d01/apps/media/media.sh up` (sources common.env automatically)
5. **Cloudflared:** `cd ~/scripts/d01/apps/cloudflared && cp .env.example .env` (set `TUNNEL_TOKEN` or `TUNNEL_ID`), then `~/scripts/d01/apps/cloudflared/cloudflared.sh up`
6. **Internal proxy (Caddy, split DNS):** lives in `asyla/projects/internal-access`, not here. From the workstation:
   `scripts/deploy-host.sh d01`, then `scripts/fleet.sh --host d01 up verify`. Secrets stay in
   `/mnt/docker/internal-proxy/.env` (`CF_API_TOKEN`, `BREEDING_PROGRAM_LAN_SECRET`).
7. SMB credentials: `~/setup_manual.sh`

**Note:** All app scripts (`media.sh up`, `cloudflared.sh up`, `internal-access.sh up`) create required networks automatically.

## Layout

- `host.toml` – the build spec read by `scripts/build_host.py` (VM shape, secrets, apps, externals).
- `setup/` – cloud-init userdata/vendor, bootstrap, deploy_software, systemConfig, nfs, smb, docker, setup_manual, setup_ssh_keys, etc.
- `apps/cloudflared/` – Cloudflare Tunnel (cloudflared.sh, compose, apps.yml, setup-tunnel-api.py).
- Internal Caddy for split DNS: `asyla/projects/internal-access` (`hosts/d01/`), deployed to `~/scripts/d01/apps/internal-access/`.
  The old `apps/internal-proxy/` was retired 2026-09-28.
- `deploy.sh` – Workstation: run `update_scripts.sh`, deploy internal-access, restart services. It pushes no secrets.
- Secrets live only on d01 (mode 600); there are no workstation copies. To rotate, edit the file on d01, then restart:
  - `/mnt/docker/cloudflared/.env` (`CLOUDFLARE_ACCOUNT_ID`, `CLOUDFLARE_ZONE_ID`, `CLOUDFLARE_API_TOKEN`, `TUNNEL_TOKEN`)
    → `~/scripts/d01/apps/cloudflared/cloudflared.sh restart`
  - `/mnt/docker/internal-proxy/.env` (`CF_API_TOKEN`, `BREEDING_PROGRAM_LAN_SECRET`)
    → `~/scripts/d01/apps/internal-access/internal-access.sh restart`
- `apps/media/` – Media stack: Sonarr, Radarr, Overseerr, Jackett, Transmission (media.sh); access via cloudflared/internal proxy.
- `update_scripts.sh`, `update.sh`, `update_all.sh` – Script update and OS maintenance. `update_scripts.sh` mirrors the
  repo into `~/scripts/d01/` and `~/scripts/docker/`: files the repo no longer has are **deleted** on the host unless a
  repo `.gitignore` matches them (secrets such as `*.env`, and the foreign app folders in `apps/.gitignore`).
  `~/update_scripts.sh --dry-run` lists what would be deleted and what is preserved.

## Application storage (`/mnt/docker`)

`/mnt/docker` is a local SSD-backed disk attached to VM 101 via Proxmox's `local-data2` LVM-thin pool on vmh01 (UUID fixed in `/etc/fstab`, ext4, mounted with `discard,nofail`). Sized 128 GiB for d01's footprint; resize the LVM-thin volume on vmh01 (`lvextend`) plus the in-VM partition + filesystem (`growpart` + `resize2fs`) if more space is needed.

Historical note: d01 originally ran with `/mnt/docker` served via iSCSI from TrueNAS (`nas01:d01:01`). That setup was migrated to local SSD on 2026-05-21 to remove iSCSI session/boot-ordering fragility (Debian Trixie bug #1090725) and to free the NAS for backup duty only. The iSCSI target and initiator config on TrueNAS can be removed once you're confident the migration is stable.
