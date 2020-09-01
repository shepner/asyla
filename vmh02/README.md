# vmh02

Installation notes of [proxmox](https://proxmox.com/en/) as a VM host

Documentation:

* [PVE admin guide](https://pve.proxmox.com/pve-docs/pve-admin-guide.html)
* [PVE wiki](https://pve.proxmox.com/wiki/Main_Page)

## Installation

Install with base options, but use ZFS mirror 1 for the disk

``` shell
bash <(curl -s https://raw.githubusercontent.com/shepner/asyla/master/`hostname -s`/update_scripts.sh)




```

## Create a cluster

Follow the instructions here: [5.3. Create a Cluster](https://pve.proxmox.com/pve-docs/pve-admin-guide.html#pvecm_create_cluster)

## Create VMs




