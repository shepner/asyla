# LXC container example

This is for a Docker Container (DCT) running Alpine Linux LXC (which wont work)

## config container

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


