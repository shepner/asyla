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
