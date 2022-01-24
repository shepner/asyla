# dhcp01

Alpine Linux LXC

## config container


In Proxmox:
* Node: VM host #1 (this is permenant due to the bind mount preventing migration)
* CT ID: 303
* Hostname: dhcp01
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
pct set 303 -mp0 /mnt/pve/nas-data2-docker/dnsmasq,mp=/mnt
```

Or the same thing:
``` shell
cat >> /etc/pve/lxc/303.conf << EOF
mp0: /mnt/pve/nas-data2-docker/dnsmasq,mp=/mnt
EOF
```


## next steps

now start the container

go run `setup/systemConfig.sh`
























# ns01

Ubuntu 20.04 Proxmox VM running DNS/DHCP services

## Install Ubuntu

Install Ubuntu 20.04 the usual way.

provide a static IP address

DNS: 208.67.222.222,208.67.220.220

Do NOT setup disk as LVM group

Install OpenSSH

## Fix the UID

First set the permissions of the home dir:

``` shell
sudo chown -R 1001 /home/`id -un`
```

Then change the UID accordingly in the passwd files:

``` shell
sudo vipw
```

Finally, logout and back in again

## Setup ssh keys

Do this from the local workstation:

``` shell
DHOST=ns01
ssh-copy-id -i ~/.ssh/shepner_rsa.pub $DHOST

#scp ~/.ssh/shepner_rsa $DHOST:.ssh/shepner_rsa
#scp ~/.ssh/shepner_rsa.pub $DHOST:.ssh/shepner_rsa.pub
#scp ~/.ssh/config $DHOST:.ssh/config
#ssh $DHOST "chmod -R 700 ~/.ssh"
```

## Configure the system

``` shell
bash <(curl -s https://raw.githubusercontent.com/shepner/asyla/master/`hostname -s`/update_scripts.sh)

~/scripts/`hostname -s`/setup/userConfig.sh
~/scripts/`hostname -s`/setup/systemConfig.sh
~/scripts/`hostname -s`/setup/nfs.sh
~/scripts/`hostname -s`/setup/docker.sh

~/update.sh
```
