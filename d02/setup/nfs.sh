#!/bin/sh

# setup NFS

doas apk update
doas apk add nfs-common

# Setup mounts

doas mkdir -p /mnt/nas/data1/docker
echo "nas:/mnt/data1/docker /mnt/nas/data1/docker nfs rw 0 0" | doas tee -a /etc/fstab
doas mkdir -p /mnt/nas/data2/docker
echo "nas:/mnt/data2/docker /mnt/nas/data2/docker nfs rw 0 0" | doas tee -a /etc/fstab

doas mount -a
