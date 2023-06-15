# ns01

Alpine Linux LXC

## config container


In Proxmox:
* Node: VM host #1 (this is permenant due to the bind mount preventing migration)
* CT ID: 302
* Hostname: ns01
* Upload the SSH public key for root (which is the only ID)

* Template: Alpine

* IPv4
  * set the IP
  * gateway
* IPv6
  * use DHCP


## mount storage

Docs:
* https://pve.proxmox.com/wiki/Unprivileged_LXC_containers
* https://www.jamescoyle.net/how-to/2019-proxmox-4-x-bind-mount-mount-storage-in-an-lxc-container
* https://pve.proxmox.com/wiki/Linux_Container#_bind_mount_points

Do this from the console of the host server:

``` shell
pct set 301 -mp0 /mnt/pve/nas-data2-docker/dnsmasq,mp=/mnt
```

Or the same thing:
``` shell
cat >> /etc/pve/lxc/301.conf << EOF
mp0: /mnt/pve/nas-data2-docker/dnsmasq,mp=/mnt
EOF
```


## next steps

now start the container

go run `setup/systemConfig.sh`


