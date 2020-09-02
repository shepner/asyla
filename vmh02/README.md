# vmh02

Installation notes of [proxmox](https://proxmox.com/en/) as a VM host

Documentation:

* [PVE admin guide](https://pve.proxmox.com/pve-docs/pve-admin-guide.html)
* [PVE wiki](https://pve.proxmox.com/wiki/Main_Page)

## Installation

Install with base options, but use ZFS mirror 1 for the disk

## Setup ssh keys

Do this from the local workstation:

``` shell
DHOST=vmh02
ssh-copy-id -i ~/.ssh/shepner_rsa.pub $DHOST
```

## Configure the system

Download the scripts:

``` shell
bash <(curl -s https://raw.githubusercontent.com/shepner/asyla/master/`hostname -s`/update_scripts.sh)

~/scripts/setup/repos.sh
~/scripts/setup/network.sh
~/scripts/setup/storage.sh
~/scripts/setup/github.sh
#~/scripts/setup/cloud-init.sh
```

## Create a cluster

Follow the instructions here: [5.3. Create a Cluster](https://pve.proxmox.com/pve-docs/pve-admin-guide.html#pvecm_create_cluster)

## Create VMs

``` shell
~/scripts/vm/blueiris.sh
~/scripts/vm/d01.sh
~/scripts/vm/fw01.sh
~/scripts/vm/ns01.sh
~/scripts/vm/plex.sh
```

