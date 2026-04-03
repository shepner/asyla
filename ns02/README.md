# ns02

Docker host VM (Debian 13, cloud-init) on Proxmox vmh02 at **10.0.0.11**, VMID **301**.

Built from the same pattern as d01/d02/d03: Debian cloud image, cloud-init, Docker, NFS/iSCSI clients, and Pi-hole DNS server.

## Build (from workstation)

```bash
cd /path/to/asyla
./ns02/build.sh
```

Requires:

- SSH to `root@vmh02`
- `ns02` in `~/.ssh/config` (HostName 10.0.0.11, User docker)
- `~/.ssh/docker_rsa.pub` for cloud-init

## After first boot

1. SSH: `ssh ns02`
2. Copy SSH keys and config from workstation (see build.sh next steps).
3. Run: `~/scripts/ns02/setup/setup_ssh_keys.sh`
4. **Pi-hole:** `~/scripts/ns02/apps/pihole/pihole.sh up`
5. iSCSI: `~/setup_manual.sh` (after adding initiator to TrueNAS for iSCSI target `nas01:ns02:01`)

**Note:** All app scripts (`pihole.sh up`) create required networks automatically.

## Layout

- `build.sh` – Destroy/create VM 301 on vmh02, import Debian cloud image, cloud-init, verify.
- `setup/` – cloud-init userdata/vendor, bootstrap, deploy_software, systemConfig, nfs, iscsi, docker, setup_manual, setup_ssh_keys, etc.
- `apps/pihole/` – Pi-hole DNS server (pihole.sh, compose.yml).
- `update_scripts.sh`, `update.sh`, `update_all.sh` – Script update and OS maintenance.

## iSCSI

Target name for ns02 on TrueNAS: `iqn.2005-10.org.freenas.ctl:nas01:ns02:01`. Add this host's initiator to the target's Initiator Group before running `~/setup_manual.sh` (iSCSI step) or `~/scripts/ns02/setup/setup_iscsi_connect.sh`. The same NAS (10.0.0.24) serves both NFS and iSCSI; mount issues at boot are due to initiator ordering, not NAS availability.

The setup script configures `/mnt/docker` to **automount at boot**. It (1) installs a systemd override so **open-iscsi.service** runs at boot (Debian Trixie bug #1090725: the unit checks `/etc/iscsi/nodes` but nodes live in `/var/lib/iscsi/nodes`), (2) sets the node to `node.startup` and `node.conn[0].startup = automatic` so `--loginall=automatic` logs in, (3) installs **mount-docker-iscsi.service** to wait for the block device then mount. Run the connect script once (after adding the initiator to TrueNAS); then reboots will auto-login and mount.

## Network Configuration

- IP: 10.0.0.11/24
- Gateway: 10.0.0.1
- DNS: 10.0.0.10, 10.0.0.11
- Search Domain: asyla.org

## Applications

### Pi-hole

DNS server providing ad-blocking and DNS resolution for the network.

- **Access:** http://10.0.0.11/admin or http://pi.hole/admin
- **DNS:** 10.0.0.11:53 (TCP/UDP)
- **Start:** `~/scripts/ns02/apps/pihole/pihole.sh up`

See [apps/pihole/README.md](apps/pihole/README.md) for details.

## Maintenance

### Updates

```bash
# Update the system
./update.sh

# Update scripts from repository
./update_scripts.sh

# Update everything
./update_all.sh
```

### Backup

Pi-hole configuration is stored in `/mnt/docker/pihole-ns02/`. Backup this directory to NFS:

```bash
tar -czf /mnt/nas/data1/docker/pihole-ns02-backup-$(date +%Y%m%d).tgz -C /mnt/docker pihole-ns02
```

## Security

- SSH key-based authentication only
- Regular security updates (unattended-upgrades configured)
- Docker security best practices
- **No sensitive information in repository**: All credentials use placeholders
- Network segmentation for DNS services

## Troubleshooting

### Cloud-init Not Installed

**Symptoms:**
- `cloud-init: command not found` when checking from console
- VM boots but configuration doesn't process automatically
- Network gets DHCP IP instead of static IP
- Docker user not created

**Solution:**

From the VM console (as root): `curl -s https://raw.githubusercontent.com/shepner/asyla/master/ns02/setup/bootstrap.sh | bash`

**If you can SSH but scripts/Docker were not installed:** Run once (as root or with sudo):  
`curl -s https://raw.githubusercontent.com/shepner/asyla/master/ns02/setup/deploy_software.sh | sudo bash`

### iSCSI mount missing or "can't find UUID" (including after boot)

**Cause:** On Debian Trixie, **open-iscsi.service** (which logs in to targets with `node.startup = automatic`) never runs at boot because it checks `ConditionDirectoryNotEmpty=/etc/iscsi/nodes`, while open-iscsi 2.1.9+ stores nodes in `/var/lib/iscsi/nodes`. So no iSCSI session is established and the block device never appears. The saved node may also have `node.startup = manual`, so even if the service runs it finds no nodes to log in (Debian bug #1090725).

**Fix (already applied if you ran the current setup):** The connect script installs the open-iscsi.service override, sets the node to automatic (both `node.startup` and `node.conn[0].startup`), and enables open-iscsi and mount-docker-iscsi. At boot: open-iscsi runs and logs in, the block device appears, then mount-docker-iscsi.service mounts `/mnt/docker`.

**If you still see the error:** Run once:  
`sudo ~/scripts/ns02/setup/setup_iscsi_connect.sh`  
(Add this host's initiator to the TrueNAS target first.) That does discovery, login, sets the node to automatic, installs override and services, and mounts for the current boot. Reboot to verify automatic login and mount. If the node was already created with `manual`, set it and reboot:  
`sudo iscsiadm -m node -T iqn.2005-10.org.freenas.ctl:nas01:ns02:01 -p 10.0.0.24 --op update -n node.startup -v automatic`  
`sudo iscsiadm -m node -T iqn.2005-10.org.freenas.ctl:nas01:ns02:01 -p 10.0.0.24 --op update -n node.conn[0].startup -v automatic`

**Immediate mount (current boot):** Run `~/setup_manual.sh` (iSCSI step) to log in and mount once.

### Network Using DHCP Instead of Static IP

**Symptoms:**
- VM gets IP like `10.0.0.248` instead of `10.0.0.11`
- `ip addr show ens18` shows DHCP-assigned address

**Solution:**
1. Install cloud-init (see above)
2. Process cloud-init configuration (see above)
3. Or manually configure network:
```bash
# Edit network config
nano /etc/netplan/50-cloud-init.yaml
# Set static IP, gateway, DNS
netplan apply
```

## Related Documentation

- [Proxmox VM Management](https://pve.proxmox.com/pve-docs/pve-admin-guide.html#_managing_virtual_machines_with_span_class_monospaced_qm_span)
- [Debian Cloud Images](https://cloud.debian.org/images/cloud/) - Download qcow2 format for Proxmox
- [Docker Installation](https://docs.docker.com/engine/install/debian/)
- [Pi-hole Documentation](https://docs.pi-hole.net/)

## Important Notes

**⚠️ PRODUCTION ENVIRONMENT**
- This is a production system - proceed with extreme caution
- Verify all steps before executing
- Backup critical data before making changes
- Test in non-production if possible

**⚠️ SECURITY**
- No sensitive information (passwords, keys, secrets) is stored in this repository
- All credentials use placeholders - must be set manually
- Review all scripts before execution
