#!/bin/sh

# Create the Proxmox VM
# [10.12. Managing Virtual Machines with qm](https://pve.proxmox.com/pve-docs/pve-admin-guide.html#_managing_virtual_machines_with_span_class_monospaced_qm_span)

# This will create a 1G disk of file and then logically resize it to to 256G but the file will remain at 1G until it fills.
# This saves the need to shrink the file later on which dramatically speeds up the process

VMID=100
qm create $VMID \
  --name d01 \
  --sockets 2 \
  --cores 10 \
  --memory 1024000 \
  --ostype l26 \
  --ide2 nas-data1-iso:iso/ubuntu-20.04.1-live-server-amd64.iso,media=cdrom \
  --scsi0 nas-data2-vm:1,format=qcow2,discard=on,ssd=1 \
  --scsihw virtio-scsi-pci \
  --bootdisk scsi0 \
  --net0 virtio,bridge=vmbr0,firewall=1 \
  --onboot 1 \
  --numa 0 \
  --agent 1,fstrim_cloned_disks=1

qm resize $VMID scsi0 512G # [resize disks](https://pve.proxmox.com/wiki/Resize_disks)

qm start $VMID
