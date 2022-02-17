# Alpine continer

This is for an Alpine Linux VM guest which will run docker 

## create VM

Create the Alpine Linux VM on Proxmox
[10.12. Managing Virtual Machines with qm](https://pve.proxmox.com/pve-docs/pve-admin-guide.html#_managing_virtual_machines_with_span_class_monospaced_qm_span)

This will create a 1G disk of file and then logically resize it to to 256G but the file will remain at 1G until it fills.
This saves the need to shrink the file later on which dramatically speeds up the process


``` shell
VMID=9999
qm create $VMID \
  --name d01 \
  --sockets 2 \
  --cores 1 \
  --memory 1024 \
  --ostype l26 \
  --ide2 nas-data1-iso:iso/alpine-virt-3.15.0-x86_64.iso,media=cdrom \
  --scsi0 nas-data1-vm:1,format=qcow2,discard=on,ssd=1 \
  --scsihw virtio-scsi-pci \
  --bootdisk scsi0 \
  --net0 virtio,bridge=vmbr1,firewall=1,tag=100 \
  --onboot 1 \
  --numa 0 \
  --agent 1,fstrim_cloned_disks=1

qm resize $VMID scsi0 16G # [resize disks](https://pve.proxmox.com/wiki/Resize_disks)

qm start $VMID
```


## configure the VM

``` shell

# patch/update
apk update \
  && apk upgrade

# set TZ
# set the tz
# https://wiki.alpinelinux.org/wiki/Setting_the_timezone
apk update \
  && apk add tzdata \
  && cp /usr/share/zoneinfo/America/Chicago /etc/localtime \
  && echo "America/Chicago" > /etc/timezone \
  && apk del tzdata

# Install sshd
# https://wiki.alpinelinux.org/wiki/Setting_up_a_SSH_server
apk update \
  && apk add openssh \
  && rc-update add sshd \
  && /etc/init.d/sshd start






# QEMU agent
# https://gitlab.alpinelinux.org/alpine/aports/-/issues/12204
apk adda qemu-guest-agent
rc-update add qemu-guest-agent boot






# Docker stuff

mkdir -p /mnt/nas/data1/docker \
  && mkdir -p /mnt/nas/data2/docker



apk update \
  && apk policy docker \
  && apk add docker \
  && addgroup root docker \
  && rc-update add docker boot \
  && service docker start

apk update \
  && apk add docker-compose \
  && addgroup root docker \
  && rc-update add docker boot \
  && service docker start

```








``` shell
#pct create 110 /mnt/nas/data2/vm/template/cache/alpine-3.15-default_20211202_amd64.tar.xz \
pct create 110 nas-data2-vm:vztmpl/alpine-3.15-default_20211202_amd64.tar.xz \
  --arch amd64 \
  --ostype alpine \
  --hostname de01 \
  --cores 1 \
  --memory 512 \
  --swap 512 \
  --storage nas-data1-vm \
  --net0 name=eth0,bridge=vmbr0,gw=10.0.0.1,ip=10.0.0.12/24,ip6=dhcp,type=veth \
  --password \
  --features nesting=1 \
  --start true


# patch/update
pct exec 110 -- sh -c " \
  apk update \
  && apk upgrade \
  "

# set TZ
# set the tz
# https://wiki.alpinelinux.org/wiki/Setting_the_timezone
pct exec 110 -- sh -c " \
  apk update \
  && apk add tzdata \
  && cp /usr/share/zoneinfo/America/Chicago /etc/localtime \
  && echo "America/Chicago" > /etc/timezone \
  && apk del tzdata \
  "


# Install sshd
# https://wiki.alpinelinux.org/wiki/Setting_up_a_SSH_server
pct exec 110 -- sh -c " \
  apk update \
  && apk add openssh \
  && rc-update add sshd \
  && /etc/init.d/sshd start \
  "

# setup the external mounts
pct exec 110 -- sh -c " \
  mkdir -p /mnt/nas/data1/docker \
  && mkdir -p /mnt/nas/data2/docker \
  "
pct stop 110 && sleep 10
pct set 110 -mp0 /mnt/pve/nas-data1-docker,mp=/mnt/nas/data1/docker
pct set 110 -mp1 /mnt/pve/nas-data2-docker,mp=/mnt/nas/data2/docker
pct start 110


# Install Docker
# https://wiki.alpinelinux.org/wiki/Docker
pct exec 110 -- sh -c " \
  apk update \
  && apk policy docker \
  && apk add docker \
  && addgroup root docker \
  && rc-update add docker boot \
  && service docker start \
  "


# THIS PART DOESNT WORK RIGHT
# Install Docker Compose
# https://wiki.alpinelinux.org/wiki/Docker
pct exec 110 -- sh -c " \
  apk update \
  && apk add docker-compose \
  && addgroup root docker \
  && rc-update add docker boot \
  && service docker start \
  "

```

### Test to see if it works

``` shell
docker run -it --rm hello-world
```

### if you need to edit the file directly

``` shell
vi /etc/pve/lxc/110.conf
```

this is to delete the container:

``` shell
pct stop 110
pct destroy 110
```


## docs/references

[tinoji/proxmox_lxc_pct_provisioner.sh]([https://gist.github.com/tinoji/7e066d61a84d98374b08d2414d9524f2)
[Create LXC Templates](https://www.chucknemeth.com/proxmox/lxc/lxc-template)

### mount storage

* https://pve.proxmox.com/wiki/Unprivileged_LXC_containers
* https://www.jamescoyle.net/how-to/2019-proxmox-4-x-bind-mount-mount-storage-in-an-lxc-container
* https://pve.proxmox.com/wiki/Linux_Container#_bind_mount_points

### Docker

http://docs.docker.com/


