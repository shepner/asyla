#!/bin/sh
# [7. Proxmox VE Storage](https://pve.proxmox.com/pve-docs/pve-admin-guide.html#chapter_storage)
# changes are stores in `/etc/pve/storage.cfg`

# [7.6. NFS Backend](https://pve.proxmox.com/pve-docs/pve-admin-guide.html#storage_nfs)
#pvesm nfsscan nas

# ISO file location
mkdir -p /mnt/nas/data1/iso
pvesm add nfs nas-data1-iso --path /mnt/nas/data1/iso --server 10.0.0.24 --export /mnt/data1/iso/proxmox --options vers=3,soft --content iso
#pvesm remove nas-data1-iso
#umount /mnt/nas/data1/iso

# VM storage (HDD)
mkdir -p /mnt/nas/data1/vm
pvesm add nfs nas-data1-vm --path /mnt/nas/data1/vm --server 10.0.0.24 --export /mnt/data1/vm/proxmox --options vers=3,soft --content images,rootdir,vztmpl,snippets,backup
#pvesm remove nas-data1-vm
#umount /mnt/nas/data1/vm

# VM storage (SSD)
mkdir -p /mnt/nas/data2/vm
pvesm add nfs nas-data2-vm --path /mnt/nas/data2/vm --server 10.0.0.24 --export /mnt/data2/vm/proxmox --options vers=3,soft --content images,rootdir,vztmpl,snippets,backup
#pvesm remove nas-data2-vm
#umount /mnt/nas/data2/vm

# make sure it worked
pvesm status
