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
   - **⚠️ NOTE**: Debian 13 cloud images SHOULD include cloud-init pre-installed. If cloud-init is missing, the image may be incomplete or corrupted. Consider:
   - Verifying the image download (checksums)
   - Using `debian-13-generic-amd64.qcow2` instead (may be more complete)
   - Re-downloading from https://cloud.debian.org/images/cloud/
   - The build script will automatically install cloud-init if missing via vendor file

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

**Option 1: Upload via SCP (from workstation)**
```bash
# Find the correct path on Proxmox host first:
ssh root@vmh02 "pvesm path nas-data1-iso"

# Then upload from workstation:
scp ~/Downloads/debian-13-nocloud-amd64.qcow2 root@vmh02:/mnt/nas/data1/iso/template/iso/
```

**Option 2: Upload via Proxmox web interface**
- Go to Datacenter → Storage → nas-data1-iso → Content → Upload
- Upload the `debian-13-nocloud-amd64.qcow2` file
- Note the path where it's stored (usually `template/iso/` subdirectory)

**Option 3: File already on Proxmox host**
If the file is already on the Proxmox host (anywhere), you can use it directly:
```bash
# Find the file location:
ssh root@vmh02 "find /mnt -name 'debian-13-nocloud-amd64.qcow2' 2>/dev/null"

# Or check common locations:
ssh root@vmh02 "ls -lh /mnt/nas/data1/iso/template/iso/debian-13-nocloud-amd64.qcow2"
ssh root@vmh02 "ls -lh /mnt/pve/nas-data1-iso/template/iso/debian-13-nocloud-amd64.qcow2"
```

**Verify file location before proceeding:**
```bash
# On Proxmox host, verify the file exists and note the full path
ssh root@vmh02 "ls -lh /mnt/nas/data1/iso/template/iso/debian-13-nocloud-amd64.qcow2"
# Or if using different storage:
ssh root@vmh02 "pvesm path nas-data1-iso"
# Then check: <path_from_pvesm>/template/iso/debian-13-nocloud-amd64.qcow2
```

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

**Recommended: Use Automated Build Script**

For fully automated builds without console copy/paste, use the `build.sh` script:

```bash
# From workstation (where repository is cloned)
cd /path/to/asyla
./d03/build.sh
```

**What the automated build does:**
- Stops and removes existing d03 VM (if present)
- Creates new VM with correct specifications
- Imports Debian cloud image (checks for both `generic` and `nocloud` variants)
- Configures Proxmox built-in cloud-init (user, network, SSH keys)
- Copies vendor file that installs cloud-init if missing and processes full config
- Sets boot order correctly
- Starts VM and waits for initialization
- Verifies SSH access

**Manual Build (Alternative)**

If you prefer manual control or need to customize the process, follow the steps below:

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
# IMPORTANT: Verify the cloud image file path first!
# Common locations:
#   - /mnt/nas/data1/iso/template/iso/debian-13-nocloud-amd64.qcow2
#   - /mnt/pve/nas-data1-iso/template/iso/debian-13-nocloud-amd64.qcow2
#   - Or wherever you uploaded it (check with: find /mnt -name 'debian-13-nocloud-amd64.qcow2')

# Verify file exists before importing:
IMAGE_PATH="/mnt/nas/data1/iso/template/iso/debian-13-nocloud-amd64.qcow2"
if [ ! -f "$IMAGE_PATH" ]; then
  echo "ERROR: Cloud image not found at $IMAGE_PATH"
  echo "Searching for file..."
  find /mnt -name 'debian-13-nocloud-amd64.qcow2' 2>/dev/null
  echo "Please update IMAGE_PATH variable with the correct path"
  exit 1
fi

# Import the disk (adjust IMAGE_PATH if file is in different location)
qm disk import $VMID \
  "$IMAGE_PATH" \
  nas-data1-vm \
  --format qcow2

# 3. Configure imported disk as scsi0 with desired properties
qm set $VMID \
  --scsi0 nas-data1-vm:$VMID/vm-$VMID-disk-0.qcow2,discard=on,ssd=1

# 4. Resize disk to 64GB
qm resize $VMID scsi0 64G

# 5. Configure VGA display for console access
qm set $VMID --vga std

# 6. Copy cloud-init vendor file to Proxmox snippets directory
# From workstation, copy the vendor file to Proxmox host:
scp d03/setup/cloud-init-vendor.yml root@vmh02:/var/lib/vz/snippets/d03-cloud-init-vendor.yml

# 7. Copy SSH public key to Proxmox host (for cloud-init)
# From workstation:
scp ~/.ssh/docker_rsa.pub root@vmh02:/tmp/docker_rsa.pub

# 8. Configure cloud-init using Proxmox built-in options + vendor file
# This approach works even if cloud-init isn't pre-installed in the image
# Proxmox generates an ISO that cloud-init reads when installed
# The vendor file installs cloud-init if missing, then processes our full config
qm set $VMID \
  --ciuser docker \
  --cipassword $(openssl passwd -6 TempPassword123!) \
  --sshkeys /tmp/docker_rsa.pub \
  --ipconfig0 ip=10.0.0.62/24,gw=10.0.0.1 \
  --nameserver '10.0.0.10 10.0.0.11' \
  --searchdomain asyla.org \
  --cicustom vendor=local:snippets/d03-cloud-init-vendor.yml

# 9. Update cloud-init configuration
qm cloudinit update $VMID

# 10. Clean up temporary SSH key file
rm -f /tmp/docker_rsa.pub

# 9. Set boot order to disk (scsi0) - IMPORTANT: Prevents network boot loop
qm set $VMID --boot order=scsi0

# 10. Verify configuration
qm config $VMID | grep -E '^boot:|^ciuser:|^ipconfig0:'

# 11. Start the VM
qm start $VMID
```

**Important Notes**:
- The cloud image will boot directly - no installation needed
- **Cloud image path**: Verify the `IMAGE_PATH` variable matches where you uploaded the file. If uploaded via web UI, check the storage path with `pvesm path nas-data1-iso` and adjust accordingly
- **Cloud-init is configured during VM creation** - network and initial user/password are set automatically
- **Boot order must be explicitly set to `scsi0`** to prevent network boot attempts
- VGA display (`--vga std`) enables console access via VNC/noVNC in Proxmox web UI
- Initial credentials: `root` / `TempPassword123!` - **change immediately after first login**

### Step 5: Initial VM Login

**⚠️ IMPORTANT: Automated Cloud-init Setup**

The build process uses Proxmox's built-in cloud-init options combined with a vendor file that:
1. **Installs cloud-init** if missing from the image (Debian cloud images should include it)
2. **Processes Proxmox's built-in config** (user, network, SSH keys)
3. **Processes our full user-data** (docker user with UID/GID, groups, additional packages)

**What gets configured automatically:**
- **User**: `docker` (created with UID 1003, GID 1000 via full user-data)
- **Groups**: `asyla` (GID 1000), `docker`, `sudo` (all configured automatically)
- **SSH Key**: Public key configured (no password needed)
- **IP Address**: `10.0.0.62` (configured via Proxmox built-in cloud-init)
- **Network**: Fully configured (DNS, gateway, search domain)
- **Packages**: cloud-init, openssh-server, curl, git installed automatically
- **SSH Service**: Enabled and started automatically

**Access the VM:**
1. Wait ~60-90 seconds for cloud-init to complete (first boot installs packages and processes config)
2. SSH to the VM using your SSH key:
   ```bash
   ssh docker@10.0.0.62
   ```
   
   **If SSH doesn't work immediately:**
   - Check console for cloud-init progress
   - Try DHCP IP if static IP not configured: `ssh docker@10.0.0.248` (or check `ip addr` from console)
   - Vendor file will install cloud-init and process full config automatically
   
   **After a rebuild:** The VM gets a new SSH host key. Edit `~/.ssh/known_hosts` on your workstation and remove the old line for `10.0.0.62` or `d03`, then connect again (or answer `yes` when SSH asks to accept the new key).
   
   No password needed - SSH key authentication is configured!

**Verify Configuration:**
```bash
# Verify docker user is configured correctly
id docker
# Should show: uid=1003(docker) gid=1000(asyla) groups=1000(asyla),27(sudo),999(docker)

groups docker
# Should include: asyla docker sudo
```

**Copy SSH Private Key and Config:**
To enable SSH to other docker hosts (d01, d02) using the same identity:

```bash
# From your workstation
scp ~/.ssh/docker_rsa d03:.ssh/docker_rsa
scp ~/.ssh/config d03:.ssh/config
ssh d03 "chmod -R 700 ~/.ssh"
```

**Note**: The vendor file automatically installs cloud-init if missing, then processes our full user-data configuration. Everything is automated - no manual console steps needed!

**Automated Build Option:**
For fully automated builds, use the `build.sh` script from the repository:
```bash
# From workstation
cd /path/to/asyla
./d03/build.sh
```

This script handles:
- VM creation and configuration
- Cloud image import
- Cloud-init setup (Proxmox built-in + vendor file)
- SSH key handling
- Initial verification

**Network Configuration**:
- IP: 10.0.0.62/24
- Gateway: 10.0.0.1
- DNS: 10.0.0.10, 10.0.0.11
- Search Domain: asyla.org

### Step 6: Verify User Account and SSH Setup

**Verify docker user is configured correctly:**
```bash
# On d03 VM
id docker
# Should show: uid=1003(docker) gid=1000(asyla) groups=1000(asyla),27(sudo),999(docker)

groups docker
# Should include: asyla docker sudo
```

**Verify SSH access:**
```bash
# From workstation, test SSH access
ssh docker@10.0.0.62 "hostname"
# Should return: d03
```

**Note**: User account and SSH public key are already configured via cloud-init. The bootstrap script handles groups and UID/GID. Private key and config are copied manually to enable SSH to other docker hosts.

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

## Network Configuration

- **Interface**: ens18 (virtio; Debian 13)
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

## Troubleshooting

### Cloud-init Not Installed

**Symptoms:**
- `cloud-init: command not found` when checking from console
- VM boots but configuration doesn't process automatically
- Network gets DHCP IP instead of static IP
- Docker user not created

**Cause:**
Some Debian 13 cloud images don't include cloud-init pre-installed, even though they're designed for cloud-init use. However, the vendor file should handle this automatically.

**Expected Behavior:**
The vendor file (`cloud-init-vendor.yml`) is designed to:
1. Install cloud-init if missing
2. Process Proxmox's built-in cloud-init config
3. Process our full user-data configuration

**If vendor file doesn't run (cloud-init not installed to process it):**

From the VM console (as root): `curl -s https://raw.githubusercontent.com/shepner/asyla/master/d03/setup/bootstrap.sh | bash`

**If you can SSH but scripts/Docker were not installed:** Run once (as root or with sudo):  
`curl -s https://raw.githubusercontent.com/shepner/asyla/master/d03/setup/deploy_software.sh | sudo bash`

**Prevention:**
- Use `debian-13-generic-amd64.qcow2` instead of `debian-13-nocloud-amd64.qcow2` (more likely to include cloud-init)
- Verify the Debian 13 cloud image includes cloud-init before use
- The build script checks for both image types and prefers the generic one
- Consider downloading a fresh image from https://cloud.debian.org/images/cloud/

### Network Using DHCP Instead of Static IP

**Symptoms:**
- VM gets IP like `10.0.0.248` instead of `10.0.0.62`
- `ip addr show ens18` shows DHCP-assigned address

**Cause:**
Cloud-init didn't process the network configuration (usually because cloud-init isn't installed or didn't run).

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