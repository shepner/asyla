#!/bin/sh

# This is intended to be a SecurityOnion manager
# https://securityonionsolutions.com/
# https://docs.securityonion.net/

# Create the VM Proxmox
VMID=602
qm create $VMID \
  --name so-srch01 \
  --sockets 2 \
  --cores 3 \
  --memory 16384 \
  --ostype l26 \
  --ide2 nas-data1-iso:iso/securityonion-2.3.100-20220203.iso,media=cdrom \
  --scsi0 nas-data1-vm:1,format=qcow2,discard=on,ssd=1 \
  --scsihw virtio-scsi-pci \
  --bootdisk scsi0 \
  --net0 virtio,bridge=vmbr1,firewall=1,tag=100 \
  --net1 virtio,bridge=vmbr1,firewall=1 \
  --onboot 1 \
  --numa 0 \
  --agent 1,fstrim_cloned_disks=1

# Expanding the disk after creation saves disk space
qm resize $VMID scsi0 256G # [resize disks](https://pve.proxmox.com/wiki/Resize_disks)

qm start $VMID

# Setup ssh keys
# Do this from the local workstation:

# install the QEMU client
sudo yum update
sudo yum -y install qemu-guest-agent.x86_64

