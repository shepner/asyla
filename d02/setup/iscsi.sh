#!/bin/sh

# setup iSCSI initiator: https://wiki.alpinelinux.org/wiki/Setting_up_iSCSI

# NOTE: Alpine seems to expect 512 byte sectors by default but will work with 4096 bytes


# install iscsi
doas apk update
doas apk add open-iscsi


# start the service
doas /etc/init.d/iscsid start
doas rc-update add iscsid boot
doas rc-update del iscsid default


# make sure it runs at startup
doas rc-update add iscsid


# point at iscsi target

IP_OF_TARGET="10.0.0.24"
#doas iscsiadm --mode discovery --type sendtargets --portal $IP_OF_TARGET

NAME_OF_TARGET="iqn.2005-10.org.freenas.ctl:data2:docker:01"  # update as appropriate
doas iscsiadm --mode node --targetname $NAME_OF_TARGET --portal $IP_OF_TARGET --login
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
  # 4096 (first sector assuming 4096 byte sectors)
  # <take the default last sector>
  # w (write to disk)
#doas fdisk -l  # validate changes

# format partition
#doas mkfs.ext4 /dev/sdb1


# update /etc/fstab
# https://unix.stackexchange.com/a/349278
doas mkdir -p /mnt/nas/data2/docker_01
echo "/dev/sdb1 /mnt/nas/data2/docker_01 ext4 _netdev,rw 0 0" | doas tee -a /etc/fstab
doas mount -a

