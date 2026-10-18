# d02

Docker host VM (Debian 13, cloud-init) at **10.0.0.61** that runs **Plex** (`apps/plex/`). The spec
(`host.toml`) is the new d02: **VM 112 on vmh02**, 1 socket x 12 cores, 16 GiB, root 64G on
`local-data2`, data disk 512G on `local-data1`, built by `scripts/build_host.py` from GitLab and the NAS
mirrors only (asyla backlog `2026-10-18-hosts-d02-replace-with-a-new-vm-built-by-build-host-py-build-new-c`).
Until its cutover the running d02 is the old **VM 102** (2x6 cores, 32 GiB, 64G + 512G on `local-data2`),
built by hand; after it, VM 102 is kept stopped as the way back. d02 was the last host in
`build_host.py`'s `LEGACY_HOSTS`: it has no `setup/` of its own (the base build scripts are
`build/setup/`, sent by the build and never kept on the host).

## Build (from workstation)

```bash
scripts/build_host.py d02 plan      # read-only: spec, live VM, gaps
scripts/build_host.py d02 build     # dry run of every phase; add --apply to act
scripts/build_host.py d02 verify    # read-only
```

The build restores Plex from its NAS mirror (`plex.sh restore`) before it starts, then checks that
Plex answers as the restored server (`plex.sh verify`). Secrets come from GitLab CI/CD variables
(`D02_*`; `build_host.py d02 secrets check`): the SMB credentials, with which `build/setup/smb.sh`
mounts `//10.0.0.24/media` at `/mnt/nas/data1/media` (Plex's `/data`).

Requires:

- SSH to the hypervisor as root (the node in `d02/host.toml`)
- `~/.ssh/docker_rsa.pub` for cloud-init

## Layout

- `host.toml` – the build spec read by `scripts/build_host.py` (VM shape, secrets, apps, runner).
- `apps/plex/` – Plex Media Server (plex.sh, compose; see its README for backups and restores).
- `apps/.gitignore` – app folders other repos deploy onto d02 (internal-access, external-access; both
  are stubs with `FLEET_ENABLED=false` today).
- `update_scripts.sh`, `update.sh`, `update_all.sh` – Script update and OS maintenance. `update_scripts.sh`
  (test01's new-host updater: it keeps no `setup/`, `host.toml` or `docker/setup/` on the host) mirrors the
  repo into `~/scripts/d02/` and `~/scripts/docker/`: files the repo no longer has are **deleted** on the
  host unless a repo `.gitignore` matches them. `~/update_scripts.sh --dry-run` lists what would be deleted
  and what is preserved.

Backups: host-maintenance runs `plex.sh backup` nightly at 00:00 Chicago (asyla/host-maintenance
`setup/schedules.py`); the new d02 has no crontab of its own (VM 102's `backup_all.sh` at 04:00 was a
duplicate).

## Application storage (`/mnt/docker`)

`/mnt/docker` is the VM's own data disk, formatted and mounted by the build (`build/setup/data_disk.sh`).
Plex's config tree is about 291G (2026-10-18: `Media/` 240G, `Metadata/` 44G), on SSD to avoid SQLite
over NFS. Its transcoder writes to `/transcode` inside the container (`Preferences.xml`
`TranscoderTempDirectory`), which compose does not mount, so transcodes land on the root disk.

## Network

- IP 10.0.0.61/24, gateway 10.0.0.1, DNS 10.0.0.10 and 10.0.0.11, search domain asyla.org (the build's
  cloud-init values); vmbr1, VLAN 100.
- Plex uses `network_mode: host` (32400 and its discovery ports on the LAN).
