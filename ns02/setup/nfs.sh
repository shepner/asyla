#!/bin/sh

# setup NFS

sudo apt update
sudo apt-get install -y nfs-common

# Setup mounts
#https://www.hiroom2.com/2017/08/22/alpinelinux-3-6-nfs-utils-client-en/

sudo mkdir -p /mnt/nas/data1/docker
echo "nas:/mnt/data1/docker /mnt/nas/data1/docker nfs rw 0 0" | sudo tee --append /etc/fstab
sudo mkdir -p /mnt/nas/data2/docker
echo "nas:/mnt/data2/docker /mnt/nas/data2/docker nfs _netdev 0 0" | sudo tee --append /etc/fstab

sudo mount -a
