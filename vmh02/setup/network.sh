#!/bin/sh

# [3.3. Network Configuration](https://pve.proxmox.com/pve-docs/pve-admin-guide.html#sysadmin_network_configuration)
# Reload Network with ifupdown2

# ifupdown2 cannot understand OpenVSwitch syntax, so reloading is not possible if OVS interfaces are configured.

apt update
apt install -y ifupdown2


