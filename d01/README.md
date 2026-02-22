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
5. **Cloudflared:** `cd ~/scripts/d01/apps/cloudflared && cp .env.example .env` (set `TUNNEL_TOKEN` or `TUNNEL_ID`), then `~/scripts/d01/apps/cloudflared/cloudflared.sh up`
6. **Internal proxy:** `~/scripts/d01/apps/internal-proxy/internal-proxy.sh up`
7. SMB + iSCSI: `~/setup_manual.sh` (after adding initiator to TrueNAS for iSCSI target `nas01:d01:01`)

**Note:** All app scripts (`media.sh up`, `cloudflared.sh up`, `internal-proxy.sh up`) create required networks automatically.

## Layout

- `build.sh` – Destroy/create VM 101 on vmh01, import Debian cloud image, cloud-init, verify.
- `setup/` – cloud-init userdata/vendor, bootstrap, deploy_software, systemConfig, nfs, smb, iscsi, docker, setup_manual, setup_ssh_keys, etc.
- `apps/cloudflared/` – Cloudflare Tunnel (cloudflared.sh, compose, apps.yml, setup-tunnel-api.py).
- `apps/internal-proxy/` – Caddy reverse proxy for split-DNS (internal-proxy.sh, Caddyfile).
- `apps/media/` – Media stack: Sonarr, Radarr, Overseerr, Jackett, Transmission (media.sh); access via cloudflared/internal proxy.
- `update_scripts.sh`, `update.sh`, `update_all.sh` – Script update and OS maintenance.

## iSCSI

Target name for d01 on TrueNAS: `iqn.2005-10.org.freenas.ctl:nas01:d01:01`. Add this host's initiator to the target's Initiator Group before running `~/setup_manual.sh` (iSCSI step) or `~/scripts/d01/setup/setup_iscsi_connect.sh`. The same NAS (10.0.0.24) serves both NFS and iSCSI; mount issues at boot are due to initiator ordering, not NAS availability.

The setup script configures `/mnt/docker` to **automount at boot**. It (1) installs a systemd override so **open-iscsi.service** runs at boot (Debian Trixie bug #1090725: the unit checks `/etc/iscsi/nodes` but nodes live in `/var/lib/iscsi/nodes`), (2) sets the node to `node.startup` and `node.conn[0].startup = automatic` so `--loginall=automatic` logs in, (3) installs **mount-docker-iscsi.service** to wait for the block device then mount. Run the connect script once (after adding the initiator to TrueNAS); then reboots will auto-login and mount.

## Troubleshooting

### iSCSI mount missing or "can't find UUID" (including after boot)

**Cause:** On Debian Trixie, **open-iscsi.service** never runs at boot because it checks `/etc/iscsi/nodes` while open-iscsi 2.1.9+ stores nodes in `/var/lib/iscsi/nodes`. The saved node may also have `node.startup = manual` (Debian bug #1090725).

**Fix:** Run once `sudo ~/scripts/d01/setup/setup_iscsi_connect.sh` (after adding initiator to TrueNAS). That installs the override, sets the node to automatic, and enables services. Reboot to verify. If the node already exists with `manual`, set it:  
`sudo iscsiadm -m node -T iqn.2005-10.org.freenas.ctl:nas01:d01:01 -p 10.0.0.24 --op update -n node.startup -v automatic`  
`sudo iscsiadm -m node -T iqn.2005-10.org.freenas.ctl:nas01:d01:01 -p 10.0.0.24 --op update -n node.conn[0].startup -v automatic`  
Then reboot. **Immediate mount:** `~/setup_manual.sh` (iSCSI step).
