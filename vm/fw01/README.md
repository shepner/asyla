# proxmox-pfsense

PFsense running as a Proxmox VM

## Create VM

run the following

``` shell
bash <(curl -s https://raw.githubusercontent.com/shepner/proxmox-pfsense/master/proxmox/create-vm.sh)
```

## Install pfsense

install/configure just enough to access from the network

## Restore

[Backup and Restore](https://docs.netgate.com/pfsense/en/latest/backup/configuration-backup-and-restore.html)

## Configure

[Disable Hardware Checksum Offloading](https://docs.netgate.com/pfsense/en/latest/virtualization/virtio-driver-support.html)

