#!/bin/sh

# setup iSCSI initiator: https://wiki.alpinelinux.org/wiki/Setting_up_iSCSI

# NOTE: Alpine seems to expect 512 byte sectors by default but will work with 4096 bytes


# install iscsi
doas apk update
doas apk add open-iscsi


# start the service
doas /etc/init.d/iscsid start


# make sure it runs at startup
doas rc-update add iscsid
doas rc-update add iscsid boot
doas rc-update del iscsid default


# point at iscsi target
IP_OF_TARGET="10.0.0.24"

# https://github.com/open-iscsi/open-iscsi

# Discover targets at a given IP address
#doas iscsiadm --mode discovery --type sendtargets --portal $IP_OF_TARGET
#doas iscsiadm --mode discoverydb --type sendtargets --portal $IP_OF_TARGET --discover

NAME_OF_TARGET="iqn.2005-10.org.freenas.ctl:nas01:ns02:01"  # update as appropriate

# Connect to the target
doas iscsiadm --mode node --targetname $NAME_OF_TARGET --portal $IP_OF_TARGET --login

# Disconnect from the target
#doas iscsiadm --mode node --targetname $NAME_OF_TARGET --portal $IP_OF_TARGET --logout 

# List node records
#doas iscsiadm --mode node

doas iscsiadm -m node -T $NAME_OF_TARGET -p $IP_OF_TARGET --op update -n node.conn[0].startup -v automatic


# (first time) setup new disk

# partition disk
# https://manjaro.site/how-to-connect-to-iscsi-volume-from-ubuntu-20-04/
# https://phoenixnap.com/kb/delete-partition-linux
#doas fdisk -l  # looking for the new device

#doas fdisk /dev/sdb
  # n (create new partition)
  # p (create primary partition)
  # 1 (create primary partition #1)
  # 512 (first sector assuming 512 byte sectors)
  # <take the default last sector>
  # w (write to disk)
#doas fdisk -l  # validate changes

# format partition
#doas mkfs.ext4 /dev/sdb1


# update /etc/fstab
# https://unix.stackexchange.com/a/349278
doas mkdir -p /mnt/docker
echo "/dev/sdb1 /mnt/docker ext4 _netdev,rw 0 0" | doas tee -a /etc/fstab
doas mount -a

