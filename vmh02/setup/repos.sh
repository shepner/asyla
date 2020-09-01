#!/bin/sh
# [package repos](https://pve.proxmox.com/pve-docs/pve-admin-guide.html#sysadmin_package_repositories)

# 3.1.1. Proxmox VE Enterprise Repository
echo '#deb https://enterprise.proxmox.com/debian/pve buster pve-enterprise' | tee /etc/apt/sources.list.d/pve-enterprise.list

# 3.1.2. Proxmox VE No-Subscription Repository
sh -c 'cat > /etc/apt/sources.list << EOF
deb http://ftp.debian.org/debian buster main contrib
deb http://ftp.debian.org/debian buster-updates main contrib

# PVE pve-no-subscription repository provided by proxmox.com,
# NOT recommended for production use
deb http://download.proxmox.com/debian/pve buster pve-no-subscription

# security updates
deb http://security.debian.org/debian-security buster/updates main contrib
EOF'

apt update
apt dist-upgrade -y
