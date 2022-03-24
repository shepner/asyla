#!/bin/sh

# CIFS support ([article](https://wiki.ubuntu.com/MountWindowsSharesPermanently))
# Use this for anything that has SMB enabled to avoid permission issues in certain situations

doas apk update
doas apk install cifs-utils

sh -c 'cat > ~/.smbcredentials << EOF
username=
password=
domain=
EOF'
chmod 600 ~/.smbcredentials

doas mkdir -p /mnt/nas/data1/media
echo "//nas/media /mnt/nas/data1/media cifs rw,uid=1003,gid=1000,credentials=/home/`id -un`/.smbcredentials 0 0" | doas tee -a /etc/fstab

echo "########################################################"
echo "Run 'vi ~/.smbcredentials' and edit the user ID/password"
echo "########################################################"
