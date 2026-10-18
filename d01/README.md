# d01

Docker host VM (Debian 13, cloud-init) at **10.0.0.60**. The spec (`host.toml`) is the new d01: **VM 111 on
vmh02**, 1 socket x 8 cores, 16 GiB, root 64G, data disk 64G (operator, 2026-10-17), built by
`scripts/build_host.py` from GitLab and the NAS mirrors only (asyla backlog
`2026-10-17-hosts-d01-replace-with-a-new-vm-built-by-build-host-py`). Until its cutover the running d01 is
the old **VM 101** (2x6 cores, 64 GiB, 128G + 128G), built by hand; after it, VM 101 is kept stopped as the
way back. d01 left `build_host.py`'s `LEGACY_HOSTS`: it has no `setup/` of its own (the base build
scripts are `build/setup/`, sent by the build and never kept on the host).

## Build (from workstation)

```bash
scripts/build_host.py d01 plan      # read-only: spec, live VM, gaps
scripts/build_host.py d01 build     # dry run of every phase; add --apply to act
scripts/build_host.py d01 verify    # read-only
```

The build restores every app from its NAS mirror (`<app>.sh restore`) before any app starts; the
internal Caddy comes from internal-access (`[[external]]`). Secrets come from GitLab CI/CD variables
(`D01_*`; `build_host.py d01 secrets check`), the SMB credentials included (`build/setup/smb.sh`
mounts `//10.0.0.24/media` at `/mnt/nas/data1/media` with them).

Requires:

- SSH to the hypervisor as root (the node in `d01/host.toml`)
- `~/.ssh/docker_rsa.pub` for cloud-init

## Layout

- `host.toml` – the build spec read by `scripts/build_host.py` (VM shape, secrets, apps, externals).
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
- `update_scripts.sh`, `update.sh`, `update_all.sh` – Script update and OS maintenance. `update_scripts.sh` (test01's
  new-host updater: it keeps no `setup/`, `host.toml` or `docker/setup/` on the host) mirrors the
  repo into `~/scripts/d01/` and `~/scripts/docker/`: files the repo no longer has are **deleted** on the host unless a
  repo `.gitignore` matches them (secrets such as `*.env`, and the foreign app folders in `apps/.gitignore`).
  `~/update_scripts.sh --dry-run` lists what would be deleted and what is preserved.

## Application storage (`/mnt/docker`)

`/mnt/docker` is the VM's own data disk (Proxmox `local-data2` LVM-thin), formatted and mounted by the build
(`build/setup/data_disk.sh`). The new d01's is 64G for about 30G of app data (Duplicati's 21G of live databases;
its 68G of pre-upgrade database copies stay in the NAS mirror and are not restored).

Historical note: d01 originally ran with `/mnt/docker` served via iSCSI from TrueNAS (`nas01:d01:01`). That setup was migrated to local SSD on 2026-05-21 to remove iSCSI session/boot-ordering fragility (Debian Trixie bug #1090725) and to free the NAS for backup duty only. The iSCSI target and initiator config on TrueNAS can be removed once you're confident the migration is stable.
