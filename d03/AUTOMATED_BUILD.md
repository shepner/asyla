# Automated Build Process for d03 VM

## Overview

The d03 VM build process is fully automated using Proxmox's built-in cloud-init options combined with a vendor file. This approach eliminates the need for console copy/paste operations.

## Architecture

### Components

1. **Proxmox Built-in Cloud-init Options**
   - `--ciuser docker`: Creates docker user
   - `--cipassword`: Sets temporary password for console access
   - `--sshkeys`: Configures SSH public key
   - `--ipconfig0`: Sets static IP (10.0.0.62/24)
   - `--nameserver`: Configures DNS servers
   - `--searchdomain`: Sets search domain (asyla.org)
   - These options generate an ISO that cloud-init reads when the VM boots

2. **Vendor File** (`cloud-init-vendor.yml`)
   - Runs additional setup commands via `runcmd`
   - Installs cloud-init if missing (fallback)
   - Fetches and processes our full user-data configuration
   - Ensures SSH service is running
   - Verifies setup completion

3. **Full User-data** (`cloud-init-userdata.yml`)
   - Defines docker user with correct UID/GID (1003/1000)
   - Creates groups (asyla GID 1000, docker, sudo)
   - Configures network (static IP on ens18)
   - Installs packages (openssh-server, curl, git)
   - Fetches setup scripts from repository

## Build Process

### Automated Build Script

Run from workstation:
```bash
cd /path/to/asyla
./d03/build.sh
```

**What it does:**
1. Stops and removes existing d03 VM (if present)
2. Creates new VM with correct specifications
3. Checks for Debian cloud images (prefers `generic`, falls back to `nocloud`)
4. Imports cloud image and configures disk
5. Copies vendor file to Proxmox snippets directory
6. Copies SSH public key to Proxmox host
7. Configures Proxmox built-in cloud-init options
8. Sets vendor file via `--cicustom vendor=local:snippets/d03-cloud-init-vendor.yml`
9. Sets boot order and starts VM
10. Waits for initialization and verifies SSH access

### Manual Build

See `README.md` for step-by-step manual instructions.

## How It Works

1. **VM Boots**: Debian cloud image boots
2. **Cloud-init Processes Proxmox ISO**: If cloud-init is installed, it reads Proxmox's generated ISO and:
   - Creates docker user
   - Configures network (static IP)
   - Sets up SSH keys
3. **Vendor File Runs**: Cloud-init processes the vendor file which:
   - Verifies/installs cloud-init if missing
   - Fetches our full user-data from GitHub
   - Processes full user-data (docker user UID/GID, groups, packages)
   - Ensures SSH service is running
   - Verifies setup

## Prerequisites

- **Debian Cloud Image**: Should include cloud-init pre-installed
  - Preferred: `debian-13-generic-amd64.qcow2`
  - Fallback: `debian-13-nocloud-amd64.qcow2`
  - Download from: https://cloud.debian.org/images/cloud/

- **SSH Keys**: `~/.ssh/docker_rsa.pub` must exist on workstation

- **Proxmox Access**: SSH access to Proxmox host (vmh02) as root

## Expected Behavior

**Normal Case (cloud-init pre-installed):**
1. VM boots
2. Cloud-init processes Proxmox's ISO (user, network, SSH keys)
3. Vendor file runs, fetches full user-data, processes it
4. SSH available at `docker@10.0.0.62` within 60-90 seconds

**Edge Case (cloud-init missing):**
1. VM boots
2. Proxmox's ISO not processed (cloud-init not installed)
3. Vendor file not processed (cloud-init not installed)
4. Manual intervention: from VM console (as root), run `curl -s https://raw.githubusercontent.com/shepner/asyla/master/d03/setup/bootstrap.sh | bash`

## Troubleshooting

### Cloud-init Not Installed

**Symptoms:**
- `cloud-init: command not found` from console
- Network gets DHCP IP instead of static IP
- Docker user not created

**Solution:**
- Use bootstrap script (see README troubleshooting section)
- Or replace with a Debian image that includes cloud-init

### SSH Not Working

**Check:**
- Wait 60-90 seconds for cloud-init to complete
- Try DHCP IP if static IP not configured: `ssh docker@10.0.0.248`
- Check console for cloud-init progress
- Verify SSH service: `systemctl status ssh`

### Network Using DHCP

**Cause:** Cloud-init didn't process network configuration

**Solution:**
- Vendor file should handle this automatically
- If not, see troubleshooting in README

## Files

- `build.sh`: Automated build script
- `setup/cloud-init-vendor.yml`: Vendor file for additional setup
- `setup/cloud-init-userdata.yml`: Full user-data configuration
- `setup/bootstrap.sh`: Fallback bootstrap script (if cloud-init missing)

## References

- Based on: https://github.com/Razuuu/Debian-CloudInit-Docs
- Proxmox Cloud-init: https://pve.proxmox.com/wiki/Cloud-Init_Support
- Debian Cloud Images: https://cloud.debian.org/images/cloud/
