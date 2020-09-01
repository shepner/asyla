#!/bin/sh

# setup NFS

sudo apt update
sudo apt-get install -y nfs-common

# Setup mounts

sudo mkdir -p /mnt/nas/data1/docker
echo "nas:/mnt/data1/docker /mnt/nas/data1/docker nfs rw 0 0" | sudo tee --append /etc/fstab

sudo mount -a
