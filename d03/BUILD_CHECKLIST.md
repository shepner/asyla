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

- [x] SSH to Proxmox host (vmh02) as root
- [x] Run VM creation command from README (verify VMID=103)
- [x] Import Debian cloud image: `qm disk import 103 ...`
- [x] Configure disk: `qm set 103 --scsi0 ...`
- [x] Resize disk: `qm resize 103 scsi0 64G`
- [x] Configure VGA: `qm set 103 --vga std`
- [x] Configure cloud-init: `qm set 103 --ciuser root --cipassword 'TempPassword123!' --ipconfig0 ip=10.0.0.62/24,gw=10.0.0.1 --nameserver '10.0.0.10 10.0.0.11' --searchdomain asyla.org`
- [x] Set boot order: `qm set 103 --boot order=scsi0` (prevents network boot loop)
- [x] Verify configuration: `qm config 103 | grep -E '^boot:|^ciuser:|^ipconfig0:'`
- [x] Start VM: `qm start 103`
- [x] Verify VM is running: `qm status 103`
- [x] Verify VM boots from disk (not network) via console

### Step 2: Initial VM Login and Bootstrap

- [ ] Wait ~30-60 seconds for cloud-init to complete (first boot)
- [ ] SSH to VM: `ssh docker@10.0.0.62` (no password - SSH key authentication)
- [ ] Verify network configuration:
  - IP: `ip addr show` (should show 10.0.0.62/24)
  - Gateway: `ip route show` (should show default via 10.0.0.1)
  - DNS: `cat /etc/resolv.conf` (should show 10.0.0.10, 10.0.0.11)
  - Test connectivity: `ping -c 3 10.0.0.1`
- [ ] Run bootstrap script to configure groups and UID/GID:
  - `curl -s https://raw.githubusercontent.com/shepner/asyla/master/d03/setup/bootstrap.sh | sudo bash`
  - Or: `sudo bash ~/scripts/d03/setup/bootstrap.sh` (if scripts already fetched)
- [ ] Verify docker user configuration:
  - `id docker` (should show uid=1003 gid=1000 groups=1000(asyla),27(sudo),999(docker))
  - `groups docker` (should include: asyla docker sudo)

### Step 3: Complete SSH Key Setup

- [ ] From workstation, copy SSH private key: `scp ~/.ssh/docker_rsa d03:.ssh/docker_rsa`
- [ ] Copy SSH config: `scp ~/.ssh/config d03:.ssh/config`
- [ ] Set permissions: `ssh d03 "chmod -R 700 ~/.ssh"`
- [ ] Test SSH access: `ssh d03 "hostname"` (should return: d03)
- [ ] Test SSH to other docker hosts: `ssh d01 "hostname"` (should work with same key)

### Step 4: Run Setup Scripts

- [ ] SSH to d03: `ssh d03`
- [ ] Update scripts from repository: `curl -s https://raw.githubusercontent.com/shepner/asyla/master/d03/update_scripts.sh | bash`
- [ ] Run systemConfig.sh: `~/scripts/d03/setup/systemConfig.sh`
- [ ] Run nfs.sh: `~/scripts/d03/setup/nfs.sh`
- [ ] Run smb.sh: `~/scripts/d03/setup/smb.sh`
- [ ] **Edit SMB credentials**: `vi ~/.smbcredentials` (add username, password, domain)
- [ ] Run iscsi.sh: `~/scripts/d03/setup/iscsi.sh` (verify TrueNAS when prompted)
- [ ] Run docker.sh: `~/scripts/d03/setup/docker.sh`
- [ ] Run system update: `~/update.sh`

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

