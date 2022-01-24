#!/bin/sh

# Set the timezone
sudo timedatectl set-timezone America/Chicago

# QEMU agent
# https://pve.proxmox.com/wiki/Qemu-guest-agent
sudo apt-get update
sudo apt-get install -y qemu-guest-agent
sudo systemctl start qemu-guest-agent

# Install net-tools
sudo apt-get update
sudo apt-get install -y net-tools

#  Disk monitoring
sudo apt update
sudo apt install -y smartmontools
#systemctl status smartd

# Disable the local dns listener (might require a reboot)
#sudo netstat -tulnp | grep 53
echo 'DNSStubListener=no' | sudo tee --append /etc/systemd/resolved.conf
sudo systemctl daemon-reload
sudo systemctl restart systemd-resolved.service
#sudo netstat -tulnp | grep 53

sudo rm /etc/resolv.conf
sudo sh -c 'cat > /etc/resolv.conf << EOF
search asyla.org
nameserver 10.0.0.5
nameserver 208.67.222.222
nameserver 208.67.220.220
EOF'
