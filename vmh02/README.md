# vmh02

Installation notes of [proxmox](https://proxmox.com/en/) as a VM host

Documentation:

* [PVE admin guide](https://pve.proxmox.com/pve-docs/pve-admin-guide.html)
* [PVE wiki](https://pve.proxmox.com/wiki/Main_Page)

## Installation

Boot drive:  ZFS (RAID1)

## Setup ssh keys

Do this from the local workstation:

``` shell
DHOST=vmh02
ssh-copy-id -i ~/.ssh/shepner_rsa.pub $DHOST
```

## Configure

Download the scripts:

``` shell
bash <(curl -s https://raw.githubusercontent.com/shepner/asyla/master/`hostname -s`/setup/github.sh)

bash <(curl -s https://raw.githubusercontent.com/shepner/asyla/master/`hostname -s`/update_scripts.sh)

~/scripts/`hostname -s`/setup/repos.sh

~/scripts/`hostname -s`/setup/network.sh

~/scripts/`hostname -s`/setup/storage.sh

#~/scripts/`hostname -s`/setup/github.sh
#~/scripts/`hostname -s`/setup/cloud-init.sh
```

## Config swap drive(s)

this may or may not be needed depending

``` shell
# https://opensource.com/article/18/9/swap-space-linux-systems

fdisk /dev/sdc
# p: check the existing partitions
# n: New parition, follow instructions, use partition 1
# p: verify change.  Should show linux filesystem
# t: select type 19 (Linux swap)
# p: verify change.  Should show linux swap
# w: write to disk

fdisk /dev/sdd
# n: New parition, follow instructions, use partition 1
# t: select type 19 (Linux swap)
# p: verify change.  Should show linux swap
# w: write to disk

# force the kernel to re-read the partition table so that it is not necessary to perform a reboot.
partprobe

# to list the partitions:
fdisk -l

# add the entries to `/etc/fstab`
echo "/dev/sdc1 swap swap defaults 0 0" >> /etc/fstab
echo "/dev/sdd1 swap swap defaults 0 0" >> /etc/fstab

# define the partition as a swap partition
mkswap /dev/sdc1
mkswap /dev/sdd1

# turn swap on
swapon -a

# to show swap space
free

# proxmox recommended level of swappiness
sysctl -w vm.swappiness=10
```

## Create/join a cluster

Follow the instructions here: [5.3. Create a Cluster](https://pve.proxmox.com/pve-docs/pve-admin-guide.html#pvecm_create_cluster)

Note that the network configs must be identical between the nodes otherwise migrations will fail.  Same goes for mountpoints, etc.

In the event you need to remove a node and you get a "cluster not ready - no quorum?" error, run `pvecm e 1` to change the needed quorum votes so the remaining node can win the vote.

## Create VMs

If needed, run the scripts in `~/scripts/vm/` which will create the VMs

