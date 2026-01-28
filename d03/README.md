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

## VM Specifications

- **VMID**: 103
- **CPU**: 6 cores, 2 sockets
- **Memory**: 25GB
- **Storage**: 64GB (qcow2 format)
- **Network**: vmbr1 bridge, VLAN 100

## Prerequisites

Before creating the VM, ensure:

1. **SSH keys are available**:
   ```bash
   # From your local workstation
   ls ~/.ssh/docker_rsa.pub
   ls ~/.ssh/docker_rsa
   ```

2. **Download Debian 13 (Trixie) Cloud Image**:
   - **⚠️ IMPORTANT**: For Proxmox, use a **cloud image** (qcow2 format), NOT an installation ISO
   - Download from: https://cloud.debian.org/images/cloud/
   - **File to download**: `debian-13-nocloud-amd64.qcow2` (64-bit AMD/Intel, qcow2 format, local QEMU virtual machine)
   - This is a pre-built cloud image - no installation needed, just configure and use
   - Place the downloaded file in your Proxmox ISO storage (e.g., `nas-data1-iso:iso/`)
   - **Why cloud image?**: Faster setup, supports cloud-init for automated configuration

3. **Proxmox host is ready**:
   - Storage volumes configured (`nas-data1-iso` for ISO storage, `nas-data1-vm` for VM storage)
   - Network bridges set up (vmbr1)
   - libguestfs-tools installed (for image customization, if needed)

## Creation Process

**⚠️ PRODUCTION ENVIRONMENT - PROCEED WITH CAUTION**

**⚠️ SECURITY: No Sensitive Information**
- All scripts use placeholders for credentials (no actual passwords/keys in repo)
- SMB credentials must be set manually after running `smb.sh`
- All sensitive files are excluded via `.gitignore`

### Step 1: Download and Prepare Debian Cloud Image

**Download the correct file:**
- Go to: https://cloud.debian.org/images/cloud/
- Download: **64-bit AMD/Intel (qcow2)** for local QEMU virtual machine
- **File name**: `debian-13-nocloud-amd64.qcow2`
- This is the "nocloud" variant - suitable for local QEMU/Proxmox VMs

**Upload to Proxmox:**
```bash
# From Proxmox host (vmh01 or vmh02) as root
# Upload the qcow2 file to ISO storage
# Example (adjust path to your ISO storage location):
scp debian-13-nocloud-amd64.qcow2 root@vmh01:/mnt/pve/nas-data1-iso/template/iso/
```

**Or use Proxmox web interface:**
- Go to Datacenter → Storage → nas-data1-iso → Content → Upload
- Upload the `debian-13-nocloud-amd64.qcow2` file

### Step 2: Verify TrueNAS (nas01) iSCSI Configuration

**⚠️ CRITICAL: Verify before proceeding**

1. **Check iSCSI target configuration**:
   - Log into TrueNAS (nas01)
   - Verify iSCSI target `iqn.2005-10.org.freenas.ctl:nas01:d03:01` exists
   - Check if initiator access controls need updating for new VM
   - Verify old d03 instance can be safely disconnected

2. **Document any required changes** before proceeding

### Step 3: Shut Down and Remove Old d03 VM

**⚠️ PRODUCTION SAFETY: Backup any critical data first**

```bash
# From Proxmox host (vmh01 or vmh02) as root
VMID=103  # Verify this is the correct VMID for old d03

# 1. Shut down the old VM
qm shutdown $VMID

# 2. Verify it's fully stopped
qm status $VMID  # Should show "stopped"

# 3. Disconnect iSCSI from old instance (if still connected)
# (This may happen automatically when VM is stopped)

# 4. Remove the old VM (⚠️ PERMANENT - ensure backups are complete)
qm destroy $VMID

# 5. Verify old VM is removed
qm list | grep d03
```

### Step 4: Create New d03 VM in Proxmox

**⚠️ PRODUCTION: Verify all values before executing**

```bash
# From Proxmox host (vmh01 or vmh02) as root via SSH
VMID=103

# 1. Create VM without disk (we'll import the cloud image separately)
qm create $VMID \
  --name d03 \
  --sockets 2 \
  --cores 6 \
  --memory 25600 \
  --ostype l26 \
  --scsihw virtio-scsi-pci \
  --net0 virtio,bridge=vmbr1,firewall=1,tag=100 \
  --onboot 1 \
  --numa 0 \
  --agent 1,fstrim_cloned_disks=1

# 2. Import Debian 13 cloud image as disk
# Note: Cloud image must be uploaded to Proxmox storage first
# Path on Proxmox host: /mnt/nas/data1/iso/template/iso/debian-13-nocloud-amd64.qcow2
qm disk import $VMID \
  /mnt/nas/data1/iso/template/iso/debian-13-nocloud-amd64.qcow2 \
  nas-data1-vm \
  --format qcow2

# 3. Configure imported disk as scsi0 with desired properties
qm set $VMID \
  --scsi0 nas-data1-vm:$VMID/vm-$VMID-disk-0.qcow2,discard=on,ssd=1

# 4. Resize disk to 64GB
qm resize $VMID scsi0 64G

# 5. Configure VGA display for console access
qm set $VMID --vga std

# 6. Set boot order to disk (scsi0) - IMPORTANT: Prevents network boot loop
qm set $VMID --boot order=scsi0

# 7. Verify boot configuration
qm config $VMID | grep '^boot:'

# 8. Start the VM
qm start $VMID
```

**Important Notes**:
- The cloud image will boot directly - no installation needed
- **Boot order must be explicitly set to `scsi0`** to prevent network boot attempts
- VGA display (`--vga std`) enables console access via VNC/noVNC in Proxmox web UI
- You'll need to configure network and user account via console or cloud-init

### Step 5: Initial VM Configuration

**Access the VM console** (via Proxmox web interface or SSH to Proxmox host):
- Default user may be `debian` or `root` (check cloud image documentation)
- You'll need to set up network, user account, and SSH access

**Network Configuration** (if not using cloud-init):
- IP: 10.0.0.62/24
- Gateway: 10.0.0.1
- DNS: 10.0.0.10, 10.0.0.11
- Search Domain: asyla.org

### Step 6: Configure User Account and SSH

**Create user account:**
```bash
# On d03 VM
sudo groupadd -g 1000 asyla
sudo useradd -u 1003 -g asyla -G docker,sudo -m -s /bin/bash docker
```

**Copy SSH keys from workstation:**
```bash
# From your local workstation
DHOST=d03
ssh-copy-id -i ~/.ssh/docker_rsa.pub $DHOST

# Copy both keys to enable SSH to other docker hosts
scp ~/.ssh/docker_rsa $DHOST:.ssh/docker_rsa
scp ~/.ssh/docker_rsa.pub $DHOST:.ssh/docker_rsa.pub
scp ~/.ssh/config $DHOST:.ssh/config
ssh $DHOST "chmod -R 700 ~/.ssh"
```

**Note**: Copying both keys enables d03 to SSH to other Docker hosts (d01, d02) using the same key identity.

### Step 7: Run Setup Scripts

**⚠️ PRODUCTION: Run scripts one at a time and verify each step**

```bash
# SSH to d03
ssh d03

# Update scripts from repository
curl -s https://raw.githubusercontent.com/shepner/asyla/master/d03/update_scripts.sh | bash

# Run setup scripts in order:
~/scripts/d03/setup/systemConfig.sh
~/scripts/d03/setup/nfs.sh
~/scripts/d03/setup/smb.sh
~/scripts/d03/setup/iscsi.sh
~/scripts/d03/setup/docker.sh

# After smb.sh, you MUST edit SMB credentials:
vi ~/.smbcredentials
# Add: username=<your_username>
# Add: password=<your_password>
# Add: domain=<your_domain>

# Run system update
~/update.sh
```

### Step 8: Configure Docker Containers

**⚠️ TODO**: Determine which containers will run on d03
- d03-old had no containers defined
- This is a greenfield opportunity to set up docker-compose
- See docker-compose configuration section below

### Step 9: Remove Cloud Image from VM

```bash
# From Proxmox host (vmh01 or vmh02) as root
VMID=103
qm set $VMID --ide2 none,media=cdrom
```

## Configuration Scripts

The following scripts are available in the `setup/` directory:

- `systemConfig.sh` - Basic system configuration
- `docker.sh` - Docker installation and configuration
- `nfs.sh` - NFS client configuration
- `smb.sh` - SMB client configuration
- `iscsi.sh` - iSCSI client configuration

## Maintenance

### Updates
```bash
# Update the system
./update.sh

# Update scripts from repository
./update_scripts.sh
```

### Backup
[Backup procedures will be documented]

### Monitoring
[Monitoring setup will be documented]

## Troubleshooting

[Common issues and solutions will be documented as encountered]

## Network Configuration

- **Interface**: eth0
- **IP**: 10.0.0.62/24
- **Gateway**: 10.0.0.1
- **DNS**: 10.0.0.10, 10.0.0.11
- **Search Domain**: asyla.org

## Security

- SSH key-based authentication only
- Regular security updates (unattended-upgrades configured)
- Docker security best practices
- **No sensitive information in repository**: All credentials use placeholders
- Network segmentation for internet-facing services
- Container isolation and least privilege principles

## Docker Management

**d03 uses docker-compose** (different from d01/d02 which use shell scripts).

This is a **greenfield opportunity** and **base template** for future docker hosts.

**Key improvements:**
- Better backup coordination (rsync-based, automated)
- Network segmentation for security
- Coordinated start/stop with dependencies
- Easier maintenance and container management
- Template for future docker hosts

**Container Requirements:**
- ⚠️ TODO: Determine which containers will run on d03
- d03-old had no containers defined - this is a fresh start

## Related Documentation

- [Proxmox VM Management](https://pve.proxmox.com/pve-docs/pve-admin-guide.html#_managing_virtual_machines_with_span_class_monospaced_qm_span)
- [Debian Cloud Images](https://cloud.debian.org/images/cloud/) - Download qcow2 format for Proxmox
- [Docker Installation](https://docs.docker.com/engine/install/debian/)
- [Debian 13 (Trixie) Release Notes](https://www.debian.org/releases/trixie/)

## Important Notes

**⚠️ PRODUCTION ENVIRONMENT**
- This is a production system - proceed with extreme caution
- Verify all steps before executing
- Backup critical data before making changes
- Test in non-production if possible

**⚠️ SECURITY**
- No sensitive information (passwords, keys, secrets) is stored in this repository
- All credentials use placeholders - must be set manually
- SMB credentials file (`.smbcredentials`) is excluded from git
- Review all scripts before execution

**Architecture Constraints:**
- Most containers use SQLite databases internally (architectural limitation)
- iSCSI storage (`/mnt/docker`) used to avoid NFS file locking issues
- Data is host-specific (backups to NFS required for resilience)
- Backup process improvements will be implemented with docker-compose