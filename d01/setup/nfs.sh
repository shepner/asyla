#!/bin/sh

# setup NFS; https://wiki.alpinelinux.org/wiki/Setting_up_a_nfs-server

doas apk update
doas apk add nfs-utils

doas rc-update add nfs
doas rc-update add nfsmount
doas rc-update add netmount

#doas rc-service nfs start
#doas rc-service nfsmount start
#doas rc-service netmount start

# Setup mounts

doas mkdir -p /mnt/nas/data1/docker
echo "nas:/mnt/data1/docker /mnt/nas/data1/docker nfs rw 0 0" | doas tee -a /etc/fstab
doas mkdir -p /mnt/nas/data2/docker
echo "nas:/mnt/data2/docker /mnt/nas/data2/docker nfs rw 0 0" | doas tee -a /etc/fstab

#doas mount -a

echo "##################################"
echo "you will need to reboot to use NFS"
echo "##################################"

