# d01

This is for an Alpine Linux VM guest which will run docker 

## create VM

Create the Alpine Linux VM on Proxmox
[10.12. Managing Virtual Machines with qm](https://pve.proxmox.com/pve-docs/pve-admin-guide.html#_managing_virtual_machines_with_span_class_monospaced_qm_span)

This will create a 1G disk of file and then logically resize it to to 256G but the file will remain at 1G until it fills.  This saves the need to shrink the file later on which dramatically speeds up the process

The [qm.conf](https://pve.proxmox.com/wiki/Manual:_qm.conf) file is located in `/etc/pve/qemu-server/<VMID>.conf`

``` shell
VMID=102
qm create $VMID \
  --name d02 \
  --sockets 2 \
  --cores 6 \
  --memory 25600 \
  --ostype l26 \
  --ide2 nas-data1-iso:iso/alpine-virt-3.15.0-x86_64.iso,media=cdrom \
  --scsi0 nas-data1-vm:1,format=qcow2,discard=on,ssd=1 \
  --scsihw virtio-scsi-pci \
  --bootdisk scsi0 \
  --net0 virtio,bridge=vmbr1,firewall=1,tag=100 \
  --onboot 1 \
  --numa 0 \
  --agent 1,fstrim_cloned_disks=1

qm resize $VMID scsi0 32G # [resize disks](https://pve.proxmox.com/wiki/Resize_disks)

qm start $VMID
```

## Install Alpine

login from the console and do the following

``` shell
setup-alpine


us
us
d01.asyla.org
eth0
10.0.0.61
255.255.255.0
10.0.0.1
n
asyla.org
10.0.0.10, 10.0.0.11
<password>
<password>
America/Chicago
none
1
openssh
sda
sys
y

reboot
```

From the VM host, remove the ISO image as its not needed anymore

``` shell
qm set $VMID \
  --ide2 none,media=cdrom
```


## Configure Alpine

if needed:
* Interface settings: `/etc/network/interfaces`
* DNS settings: `/etc/resolv.conf`


### config a user account

``` shell
addgroup -g 1000 asyla
adduser -u 1001 -G asyla -g "shepner" shepner
```

### doas

``` shell
adduser shepner wheel

apk add doas
echo "permit nopass :wheel" >> /etc/doas.conf
```

### SSH

from local workstation, copy over the ssh keys

``` shell
DHOST=d02
ssh-copy-id -i ~/.ssh/shepner_rsa.pub $DHOST

scp ~/.ssh/shepner_rsa $DHOST:.ssh/shepner_rsa
scp ~/.ssh/shepner_rsa.pub $DHOST:.ssh/shepner_rsa.pub
scp ~/.ssh/config $DHOST:.ssh/config
ssh $DHOST "chmod -R 700 ~/.ssh"
```


run the setup scripts:
``` shell
doas apk add curl git
ash <(curl -s https://raw.githubusercontent.com/shepner/asyla/master/`hostname -s`/update_scripts.sh)

~/scripts/`hostname -s`/setup/systemConfig.sh
~/scripts/`hostname -s`/setup/smb.sh
~/scripts/`hostname -s`/setup/nfs.sh
~/scripts/`hostname -s`/setup/docker.sh

~/update.sh
```


## Configure Docker Swarm

Manager commands

``` shell
# Initial setup
doas docker swarm init --advertise-addr <IP>

# Generate manager token
doas docker swarm join-token manager

# Generate worker token
doas docker swarm join-token worker
```

Follow the instructions provided and run the command on each of the other (worker) nodes as appropriate:

``` shell
doas docker swarm join --token <TOKEN> <IP>:2377
```

Check on the status of the cluster
``` shell
doas docker node ls
```

