# d03

This is for a Debian Linux VM on Proxmox which will run Docker containers.

## Overview

- **VM Name**: d03
- **Hostname**: d03.asyla.org
- **IP Address**: 10.0.0.62/24
- **Gateway**: 10.0.0.1
- **DNS**: 10.0.0.10, 10.0.0.11
- **Purpose**: Docker host for containerized applications
- **OS**: Debian 13 (Trixie) - Current stable release

**Applications:** See [apps/README.md](apps/README.md) for the current app list and which repo owns each one. This repo owns `breeding-research`, `tc-datalogger`, `ms-procedural-backup` and `ms-chronicle-backup` (agent-commons was retired 2026-10-08: replaced by ms-procedural on the Mac Mini; Gitea moved to d04 on 2026-10-16); the edge stack is deployed separately from `asyla/projects/`.

**Internet access:** Applications on d03 are exposed via **Cloudflare Tunnel** (no port forwarding required), terminated by `external-access` with `internal-access` (Caddy) fronting split-DNS on ports 80/443. Both are deployed from their own repos under `asyla/projects/` via `scripts/deploy-host.sh d03`. [docs/cloudflare-tunnel.md](docs/cloudflare-tunnel.md) describes the superseded `cloudflared` / `internal-proxy` layout and is kept for historical reference only.

## VM Specifications

The build spec is [host.toml](host.toml) (`[vm]`): the rebuilt d03 has 1 socket, 6 cores, 8 GiB,
a 32G OS disk and a 32G data disk (`/mnt/docker`) on vmh01 `local-data2`, under a new VMID. VM 103,
the old d03, is kept stopped as the way back.

- **Network**: vmbr1 bridge, VLAN 100

## Build

The build path is `scripts/build_host.py` with the spec in [host.toml](host.toml), the same as d04
and test01: its setup steps come from `build/setup/` (d03 has no `setup/` of its own since it left
build_host.py's legacy hosts). It is dry by default; `--apply` acts.

```bash
# From the workstation (where this repository is cloned)
scripts/build_host.py d03 plan      # read-only: spec, live VM, gaps
scripts/build_host.py d03 build     # dry run of every phase; add --apply to act
scripts/build_host.py d03 verify    # read-only
```

- **d04 first**: the runner registers with Gitea on d04 and the app images come from its registry.
- **New VMID**: `[vm].vmid` is the operator's choice, set before the build; never 103.
- **The way back**: VM 103 (the old d03) is shut down and kept, stopped, not destroyed. Destroying
  it is a separate, later approval once the rebuilt d03 has run cleanly.
- The old manual procedure (cloud image, iSCSI `/mnt/docker`, `d03/setup/*.sh`) is in git history:
  `git show 2422456:d03/README.md`.

## Maintenance

### Updates
```bash
# Update the system
./update.sh

# Update scripts from repository
./update_scripts.sh
```

`update_scripts.sh` mirrors the repo into `~/scripts/d03/` and `~/scripts/docker/`: files the repo no longer has
are **deleted** on the host unless a repo `.gitignore` matches them (secrets such as `*.env`, and the foreign app
folders in `apps/.gitignore`). `~/update_scripts.sh --dry-run` lists what would be deleted and what is preserved.
It is test01's and d04's updater: it then removes the build files (`d03/setup/`, `d03/host.toml`,
`docker/setup/`), which the build sends only when it needs them (`build_host.py` `build_only_paths`).

### Comprehensive update (update_all)
`./update_all.sh` (as root or with sudo) runs in order: (1) update_scripts, (2) OS update, (3) backup and upgrade each app under `~/scripts/<host>/apps/`. Step 3 runs **one screen session per app** (parallel and disconnect-safe). If your SSH session drops, reattach with `screen -r update_<host>_<app>` to watch that app; the main script polls until all apps finish. Results are written to `~/logs/update_all/run_<timestamp>/` (per-app `.exit` codes, `summary.txt`, wrapper scripts).

### Auditing update_all runs
From your **local workstation** (in the asyla repo), run the helper to check the latest run on each host via SSH:
```bash
.cursor/helpers/audit_update_all.sh              # default hosts: d01 d02 d03 ns01 ns02
.cursor/helpers/audit_update_all.sh d01 d03     # specific hosts
```
Exit 0 = every host has a run with no failures; exit 1 = one or more hosts have failures or no run. The helper fetches `~/logs/update_all/latest` → `summary.txt` from each host.

### Backup
Nightly from host-maintenance (gitlab.com/asyla/host-maintenance, `TASK=backup HOSTS=d03`), one app at a time. Each `<app>.sh backup` updates one rsync mirror at `/mnt/nas/data1/docker/<App>/mirror`; history is nas01's daily ZFS snapshots (2 weeks). See [apps/README.md](apps/README.md).

### Monitoring
[Monitoring setup will be documented]

## Network Configuration

- **Interface**: ens18 (virtio; Debian 13)
- **IP**: 10.0.0.62/24
- **Gateway**: 10.0.0.1
- **DNS**: 10.0.0.10, 10.0.0.11
- **Search Domain**: asyla.org

