# d01

This is for an Alpine Linux VM guest which will run docker 

## create VM

Create the Alpine Linux VM on Proxmox
[10.12. Managing Virtual Machines with qm](https://pve.proxmox.com/pve-docs/pve-admin-guide.html#_managing_virtual_machines_with_span_class_monospaced_qm_span)

This will create a 1G disk of file and then logically resize it to to 256G but the file will remain at 1G until it fills.  This saves the need to shrink the file later on which dramatically speeds up the process

The [qm.conf](https://pve.proxmox.com/wiki/Manual:_qm.conf) file is located in `/etc/pve/qemu-server/<VMID>.conf`

``` shell
VMID=304
qm create $VMID \
  --name ns01-pihole \
  --sockets 2 \
  --cores 2 \
  --memory 2048 \
  --ostype l26 \
  --ide2 nas-data1-iso:iso/alpine-virt-3.18.2-x86_64.iso,media=cdrom \
  --scsi0 nas-data1-vm:1,format=qcow2,discard=on,ssd=1 \
  --scsihw virtio-scsi-pci \
  --bootdisk scsi0 \
  --net0 virtio,bridge=vmbr1,firewall=1,tag=100 \
  --onboot 1 \
  --numa 0 \
  --agent 1,fstrim_cloned_disks=1
```

Wait a min or 2

``` shell
qm resize $VMID scsi0 64G # [resize disks](https://pve.proxmox.com/wiki/Resize_disks)
```

Wait a min or 2

``` shell
qm start $VMID
```

## Install Alpine

login from the console (root, no passwd) and do the following

``` shell
setup-alpine


us
us
ns01.asyla.org
eth0
10.0.0.10
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
no
openssh
prohibit-password
none
sda
sys
y

reboot
```

From the VM host, remove the ISO image as its not needed anymore:

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
adduser -u 1003 -G asyla -g "docker" docker
```

### doas

``` shell
adduser docker wheel

apk add doas
echo "permit nopass :wheel" >> /etc/doas.d/doas.conf
```

### SSH

from local workstation, copy over the ssh keys

``` shell
DHOST=ns01
ssh-copy-id -i ~/.ssh/docker_rsa.pub $DHOST

scp ~/.ssh/docker_rsa $DHOST:.ssh/docker_rsa
scp ~/.ssh/docker_rsa.pub $DHOST:.ssh/docker_rsa.pub
scp ~/.ssh/config $DHOST:.ssh/config
ssh $DHOST "chmod -R 700 ~/.ssh"
```

### configure system

run the setup scripts:

``` shell
doas apk add curl git
ash <(curl -s https://raw.githubusercontent.com/shepner/asyla/master/`hostname -s`/update_scripts.sh)

~/scripts/`hostname -s`/setup/systemConfig.sh
```

run this by hand the first time

``` shell
~/scripts/`hostname -s`/setup/iscsi.sh
```


``` shell
~/scripts/`hostname -s`/setup/nfs.sh
~/scripts/`hostname -s`/setup/docker.sh

~/update.sh

doas reboot
```

