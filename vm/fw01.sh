#!/bin/sh

# https://docs.netgate.com/pfsense/en/latest/virtualization/virtualizing-pfsense-with-proxmox.html

# Create the Proxmox VM
# [10.12. Managing Virtual Machines with qm](https://pve.proxmox.com/pve-docs/pve-admin-guide.html#_managing_virtual_machines_with_span_class_monospaced_qm_span)

# This will create a 1G disk of file and then logically resize it to to 256G but the file will remain at 1G until it fills.
# This saves the need to shrink the file later on which dramatically speeds up the process

VMID=500
qm create $VMID \
  --name fw01 \
  --sockets 1 \
  --cores 2 \
  --memory 2048 \
  --ostype other \
  --ide2 nas-data1-iso:iso/pfSense-CE-2.4.5-RELEASE-p1-amd64.iso,media=cdrom \
  --scsi0 nas-data2-vm:1,format=qcow2,discard=on,ssd=1 \
  --scsihw virtio-scsi-pci \
  --bootdisk scsi0 \
  --net0 virtio,bridge=vmbr1,firewall=1,tag=100 \ \
  --net1 virtio,bridge=vmbr1,firewall=1,tag=300 \
  --net2 virtio,bridge=vmbr1,firewall=1,tag=103 \
  --onboot 1 \
  --numa 0 \
  --agent 1,fstrim_cloned_disks=1
  
qm resize $VMID scsi0 8G # [resize disks](https://pve.proxmox.com/wiki/Resize_disks)

qm start $VMID
