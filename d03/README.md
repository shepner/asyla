# d03

This is for a Debian Linux VM on Proxmox which will run Docker containers.

## Overview

- **VM Name**: d03
- **Hostname**: d03.asyla.org
- **IP Address**: 10.0.0.62/24
- **Gateway**: 10.0.0.1
- **DNS**: 10.0.0.10, 10.0.0.11
- **Purpose**: Docker host for containerized applications
- **OS**: Debian 12 (Bookworm)

## VM Specifications

- **VMID**: TBD
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
   ```

2. **Proxmox host is ready**:
   - Storage volumes configured
   - Network bridges set up
   - libguestfs-tools installed (for image customization)

## Creation Process

### Step 1: Prepare Base Image
[Documentation will be added as you perform the steps]

### Step 2: Create VM in Proxmox
[Documentation will be added as you perform the steps]

### Step 3: Configure VM
[Documentation will be added as you perform the steps]

### Step 4: Install and Configure Docker
[Documentation will be added as you perform the steps]

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
- Regular security updates
- Docker security best practices

## Related Documentation

- [Proxmox VM Management](https://pve.proxmox.com/pve-docs/pve-admin-guide.html#_managing_virtual_machines_with_span_class_monospaced_qm_span)
- [Debian Cloud Images](https://cloud.debian.org/images/cloud/)
- [Docker Installation](https://docs.docker.com/engine/install/debian/)