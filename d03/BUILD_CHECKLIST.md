# d03 Build Checklist

This checklist guides you through the complete build process for the new d03 VM.

## Pre-Build Checklist

### Prerequisites Verification

- [x] SSH keys available on workstation (`~/.ssh/docker_rsa` and `~/.ssh/docker_rsa.pub`)
- [x] Proxmox hosts (vmh01/vmh02) accessible via SSH with root key
- [x] TrueNAS (nas01) accessible for iSCSI verification
- [x] Debian 13 cloud image downloaded: `debian-13-nocloud-amd64.qcow2`
- [x] Cloud image uploaded to Proxmox ISO storage (`nas-data1-iso:iso/`)

### TrueNAS iSCSI Verification

- [x] Log into TrueNAS (nas01)
- [x] Verify iSCSI target exists: `iqn.2005-10.org.freenas.ctl:nas01:d03:01`
- [x] Check initiator access controls (may need updating for new VM)
- [x] Verify old d03 instance can be safely disconnected
- [x] Document any required changes

**Documented Changes Required:**
- After new d03 VM is set up, update Initiator Group 3 in TrueNAS with the new VM's IQN
- Current Group 3 IQN: `iqn.2016-04.com.open-iscsi:5e1d682255e` (old d03)
- New IQN will be generated when `open-iscsi` is installed on new d03
- Update will be done during `iscsi.sh` setup script execution

### Old d03 Shutdown

- [x] Backup any critical data from old d03
- [x] Shut down old d03 VM: `qm shutdown 103`
- [x] Verify old d03 is fully stopped: `qm status 103`
- [x] Remove old d03 VM: `qm destroy 103` (⚠️ PERMANENT)
- [x] Verify old VM is removed: `qm list | grep d03`

## Build Process

### Step 1: Create VM in Proxmox

**Option A: Automated Build (Recommended)**
- [ ] Run automated build script from workstation. Paths are script-relative, so either:
  - From repo root: `./d03/build.sh`
  - From d03: `./build.sh`
- [ ] Script handles all steps automatically (VM creation, cloud-init setup, verification)
- [ ] Wait for script to complete and verify SSH access

**Option B: Manual Build**
- [ ] SSH to Proxmox host (vmh02) as root
- [ ] Run VM creation command from README (verify VMID=103)
- [ ] Import Debian cloud image: `qm disk import 103 ...`
- [ ] Configure disk: `qm set 103 --scsi0 ...`
- [ ] Resize disk: `qm resize 103 scsi0 64G`
- [ ] Configure VGA: `qm set 103 --vga std`
- [ ] Copy cloud-init vendor file to Proxmox: `scp d03/setup/cloud-init-vendor.yml root@vmh02:/var/lib/vz/snippets/d03-cloud-init-vendor.yml`
- [ ] Copy SSH public key to Proxmox: `scp ~/.ssh/docker_rsa.pub root@vmh02:/tmp/docker_rsa.pub`
- [ ] Configure Proxmox built-in cloud-init + vendor file:
  ```bash
  qm set 103 --ciuser docker \
    --cipassword $(openssl passwd -6 TempPassword123!) \
    --sshkeys /tmp/docker_rsa.pub \
    --ipconfig0 ip=10.0.0.62/24,gw=10.0.0.1 \
    --nameserver '10.0.0.10 10.0.0.11' \
    --searchdomain asyla.org \
    --cicustom vendor=local:snippets/d03-cloud-init-vendor.yml
  qm cloudinit update 103
  rm -f /tmp/docker_rsa.pub
  ```
- [ ] Set boot order: `qm set 103 --boot order=scsi0` (prevents network boot loop)
- [ ] Verify configuration: `qm config 103 | grep -E '^boot:|^ciuser:|^ipconfig0:|^cicustom:'`
- [ ] Start VM: `qm start 103`
- [ ] Verify VM is running: `qm status 103`

### Step 2: Initial VM Login

**✅ Fully automated by Proxmox built-in cloud-init + vendor file:**
- Vendor file installs cloud-init if missing (Debian images should include it)
- Docker user created automatically (UID 1003, GID 1000) via full user-data
- Groups created automatically (asyla GID 1000, docker, sudo)
- SSH public key: Proxmox `--sshkeys` is preserved when the vendor re-runs cloud-init with userdata (vendor backs up/restores `authorized_keys` so your `docker_rsa.pub` is used)
- Network configured automatically (IP, gateway, DNS, search domain) via Proxmox built-in
- Initial packages installed (cloud-init, openssh-server, curl, git)
- SSH service enabled and started automatically
- Setup scripts fetched automatically

**Verification steps:**
- [ ] Wait ~60-90 seconds for cloud-init to complete (first boot installs packages and processes config)
- [ ] **Check cloud-init status** (from console if SSH not ready):
  - `command -v cloud-init` (should show `/usr/bin/cloud-init` after vendor file runs)
  - `cloud-init status` (should show "status: done" when complete)
  - If cloud-init not found initially, vendor file will install it automatically
- [ ] SSH to VM: `ssh docker@10.0.0.62` (no password - SSH key authentication)
  - If SSH fails, try DHCP IP: `ssh docker@10.0.0.248` (or check `ip addr` from console)
  - Vendor file ensures SSH service is running
- [ ] **After a rebuild:** The VM gets a new host key. SSH will warn that the host key for `10.0.0.62` or `d03` has changed. Edit `~/.ssh/known_hosts` on your workstation and remove the old line for `10.0.0.62` or `d03`, then connect again (or answer `yes` when SSH asks to accept the new key).
- [ ] Verify network configuration:
  - IP: `ip addr show ens18` (should show 10.0.0.62/24)
  - Gateway: `ip route show` (should show default via 10.0.0.1)
  - DNS: `cat /etc/resolv.conf` (should show 10.0.0.10, 10.0.0.11)
  - Test connectivity: `ping -c 3 10.0.0.1`
- [ ] Verify docker user configuration:
  - `id docker` (should show uid=1003 gid=1000 groups=1000(asyla),27(sudo),999(docker))
  - `groups docker` (should include: asyla docker sudo)
- [ ] Verify setup scripts were fetched: `ls ~/scripts/d03/setup/`

**Note**: The vendor file (`cloud-init-vendor.yml`) handles cloud-init installation if missing, then processes our full user-data configuration. Everything is automated - no console copy/paste needed!

### Step 3: Complete SSH Key Setup

**✅ Automated by cloud-init:**
- SSH public key already configured (enables passwordless SSH to d03)

**Manual steps (required for SSH to other docker hosts):**
- [ ] From workstation, copy SSH private key: `scp ~/.ssh/docker_rsa d03:.ssh/docker_rsa`
- [ ] Copy SSH config: `scp ~/.ssh/config d03:.ssh/config`
- [ ] Set permissions: `ssh d03 "chmod -R 700 ~/.ssh"`
- [ ] Test SSH access: `ssh d03 "hostname"` (should return: d03)
- [ ] Test SSH to other docker hosts: `ssh d01 "hostname"` (should work with same key)

**Note**: Private key and config must be copied manually for security reasons (not stored in cloud-init).

### Step 4: Run Setup Scripts

**✅ Automated by custom cloud-init user-data:**
- Scripts fetched automatically from repository

**Must remain manual (requires verification/credentials):**
- [ ] If scripts were not fetched by cloud-init, from workstation run: `./d03/deploy_scripts_to_d03.sh` (pushes setup and update scripts to d03)
- [ ] SSH to d03: `ssh d03`
- [ ] Verify scripts are present: `ls ~/scripts/d03/setup/` (should show systemConfig.sh, nfs.sh, smb.sh, iscsi.sh, docker.sh)
- [ ] Run systemConfig.sh: `sudo ~/scripts/d03/setup/systemConfig.sh`
- [ ] Run nfs.sh: `sudo ~/scripts/d03/setup/nfs.sh`
- [ ] Run smb.sh: `sudo ~/scripts/d03/setup/smb.sh`
- [ ] **Edit SMB credentials**: `vi ~/.smbcredentials` (add username, password, domain)
- [ ] Run iscsi.sh: `sudo ~/scripts/d03/setup/iscsi.sh` (verify TrueNAS when prompted)
- [ ] Run docker.sh: `sudo ~/scripts/d03/setup/docker.sh`
- [ ] Run system update: `sudo ~/update.sh`

**Note**: Script fetching could be automated via custom cloud-init user-data, but execution must remain manual as some scripts require:
- SMB credentials (security-sensitive)
- iSCSI target verification (safety check)
- Manual review of configuration changes

### Step 5: Verify Mounts

- [ ] Verify NFS mounts: `mount | grep nfs`
- [ ] Test NFS mount: `mount /mnt/nas/data1/docker` (if needed)
- [ ] Verify SMB mount: `mount | grep cifs`
- [ ] Test SMB mount: `mount /mnt/nas/data1/media` (if needed)
- [ ] Verify iSCSI connection: `iscsiadm -m session`
- [ ] Verify iSCSI device: `lsblk` or `fdisk -l`
- [ ] Test iSCSI mount: `mount /mnt/docker` (if needed)

### Step 6: Verify Docker

- [ ] Verify Docker is running: `docker ps`
- [ ] Verify Docker Compose: `docker compose version`
- [ ] Test Docker: `docker run --rm hello-world`

### Step 7: Configure Docker Containers

- [ ] Determine which containers will run on d03
- [ ] Add containers to `docker-compose.yml`
- [ ] Configure networks (internet/internal/backend as appropriate)
- [ ] Set resource limits
- [ ] Add healthchecks
- [ ] Test container startup: `docker compose up -d`

### Step 8: Final Cleanup

- [ ] Remove cloud image from VM: `qm set 103 --ide2 none,media=cdrom`
- [ ] Verify all services are running
- [ ] Test backup process (when implemented)
- [ ] Document any custom configurations

## Post-Build Verification

### System Health

- [ ] System updates working: `~/update.sh`
- [ ] Script updates working: `~/update_scripts.sh`
- [ ] Comprehensive update working: `~/update_all.sh`
- [ ] Docker containers starting correctly
- [ ] All mounts accessible

### Security Verification

- [ ] No sensitive information in repository (verified)
- [ ] SMB credentials file not in repository (check `.gitignore`)
- [ ] SSH keys properly secured (600 permissions)
- [ ] Network segmentation working (if containers defined)
- [ ] Resource limits applied (if containers defined)

### Documentation

- [ ] README.md reviewed and accurate
- [ ] docker-compose.README.md reviewed
- [ ] All scripts documented
- [ ] Any custom configurations documented

## Troubleshooting

### Cloud-init missing / No SSH / Can't paste in console

If the VM has no cloud-init (`command -v cloud-init` shows nothing), SSH is not running, and the console does not support paste:

1. **On your workstation** (or Proxmox host, from a shell with the repo):
   ```bash
   ./d03/setup/serve_bootstrap.sh
   ```
   Note the `HOST_IP` it prints (e.g. `10.0.0.50`).

2. **In the Proxmox VM console**, as root, type only (replace with your host IP):
   ```text
   curl http://10.0.0.50:8888/b | bash
   ```
   Short filename `b` keeps typing minimal. When the bootstrap finishes, SSH will be available at `docker@10.0.0.62` (or at the current DHCP IP if static is not yet applied).

3. Stop the server on the workstation with Ctrl+C when done.

### Common Issues

**VM won't start:**
- Check Proxmox logs: `journalctl -u pve-cluster`
- Verify storage: `pvesm status`
- Check VM configuration: `qm config 103`

**Network issues:**
- Verify network bridge: `ip addr show vmbr1`
- Check VLAN tagging: `qm config 103 | grep net`
- Test connectivity: `ping 10.0.0.1`

**iSCSI connection fails:**
- Verify TrueNAS configuration
- Check network connectivity: `ping 10.0.0.24`
- Check iscsid service: `systemctl status iscsid`
- Review iSCSI logs: `journalctl -u iscsid`

**Docker issues:**
- Check Docker service: `systemctl status docker`
- Verify Docker group: `groups docker`
- Check Docker logs: `journalctl -u docker`

## Notes

- All scripts automatically clean up after themselves
- Package cache is managed automatically
- Old kernels are removed automatically via unattended-upgrades
- No sensitive information is stored in repository
- All credentials must be set manually

## Support

- See `README.md` for detailed documentation
- See `docker-compose.README.md` for Docker management
- Review setup scripts for configuration details

