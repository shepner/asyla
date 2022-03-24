#!/bin/sh

# setup NFS

sudo apt update
sudo apt-get install -y nfs-common

# Setup mounts

sudo mkdir -p /mnt/nas/data1/docker
echo "nas:/mnt/data1/docker /mnt/nas/data1/docker nfs rw 0 0" | sudo tee --append /etc/fstab
sudo mkdir -p /mnt/nas/data2/docker
echo "nas:/mnt/data2/docker /mnt/nas/data2/docker nfs rw 0 0" | sudo tee --append /etc/fstab

sudo mount -a
