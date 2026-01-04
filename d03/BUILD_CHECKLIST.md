# d03 Build Checklist

This checklist guides you through the complete build process for the new d03 VM.

## Pre-Build Checklist

### Prerequisites Verification

- [ ] SSH keys available on workstation (`~/.ssh/docker_rsa` and `~/.ssh/docker_rsa.pub`)
- [ ] Proxmox hosts (vmh01/vmh02) accessible via SSH with root key
- [ ] TrueNAS (nas01) accessible for iSCSI verification
- [ ] Debian 13 cloud image downloaded: `debian-13-nocloud-amd64.qcow2`
- [ ] Cloud image uploaded to Proxmox ISO storage (`nas-data1-iso:iso/`)

### TrueNAS iSCSI Verification

- [ ] Log into TrueNAS (nas01)
- [ ] Verify iSCSI target exists: `iqn.2005-10.org.freenas.ctl:nas01:d03:01`
- [ ] Check initiator access controls (may need updating for new VM)
- [ ] Verify old d03 instance can be safely disconnected
- [ ] Document any required changes

### Old d03 Shutdown

- [ ] Backup any critical data from old d03
- [ ] Shut down old d03 VM: `qm shutdown 103`
- [ ] Verify old d03 is fully stopped: `qm status 103`
- [ ] Remove old d03 VM: `qm destroy 103` (⚠️ PERMANENT)
- [ ] Verify old VM is removed: `qm list | grep d03`

## Build Process

### Step 1: Create VM in Proxmox

- [ ] SSH to Proxmox host (vmh01 or vmh02) as root
- [ ] Run VM creation command from README (verify VMID=103)
- [ ] Resize disk: `qm resize 103 scsi0 64G`
- [ ] Start VM: `qm start 103`
- [ ] Verify VM is running: `qm status 103`

### Step 2: Initial VM Configuration

- [ ] Access VM console (via Proxmox web interface)
- [ ] Configure network (if not using cloud-init):
  - IP: 10.0.0.62/24
  - Gateway: 10.0.0.1
  - DNS: 10.0.0.10, 10.0.0.11
  - Search Domain: asyla.org
- [ ] Create user account: `docker` (UID 1003, GID 1000)
- [ ] Add user to `sudo` group
- [ ] Test network connectivity: `ping 10.0.0.1`

### Step 3: SSH Key Setup

- [ ] From workstation, copy SSH public key: `ssh-copy-id -i ~/.ssh/docker_rsa.pub d03`
- [ ] Copy private key: `scp ~/.ssh/docker_rsa d03:.ssh/docker_rsa`
- [ ] Copy public key: `scp ~/.ssh/docker_rsa.pub d03:.ssh/docker_rsa.pub`
- [ ] Copy SSH config: `scp ~/.ssh/config d03:.ssh/config`
- [ ] Set permissions: `ssh d03 "chmod -R 700 ~/.ssh"`
- [ ] Test SSH access: `ssh d03 "hostname"`

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

