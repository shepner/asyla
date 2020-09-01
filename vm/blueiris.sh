#!/bin/sh

# https://pve.proxmox.com/wiki/Windows_10_guest_best_practices

sudo wget -O /mnt/nas/data1/iso/template/iso/virtio-win.iso https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/stable-virtio/virtio-win.iso


# Create the Proxmox VM
# [10.12. Managing Virtual Machines with qm](https://pve.proxmox.com/pve-docs/pve-admin-guide.html#_managing_virtual_machines_with_span_class_monospaced_qm_span)

# This will create a 1G disk of file and then logically resize it to to 256G but the file will remain at 1G until it fills.
# This saves the need to shrink the file later on which dramatically speeds up the process

VMID=400
qm create $VMID \
  --name blueiris \
  --sockets 1 \
  --cores 2 \
  --memory 4096 \
  --ostype win10 \
  --ide2 nas-data1-iso:iso/Win10_2004_English_x64.iso,media=cdrom \
  --ide3 nas-data1-iso:iso/virtio-win.iso,media=cdrom \
  --scsi0 nas-data1-vm:1,format=qcow2,discard=on,ssd=1 \
  --scsihw virtio-scsi-pci \
  --bootdisk scsi0 \
  --net0 virtio,bridge=vmbr0,firewall=1 \
  --onboot 1 \
  --numa 0 \
  --agent 1,fstrim_cloned_disks=1 \
  --vga virtio,memory=16

qm resize $VMID scsi0 256G # [resize disks](https://pve.proxmox.com/wiki/Resize_disks)

qm start $VMID
