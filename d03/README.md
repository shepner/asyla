# d01

This is for a Debian Linux VM on Proxmox which will run docker

based upon https://alshowto.com/proxmox-and-debian-12-cloud-image/

Make sure the ssh public key is out there

``` shell
# user ssh keys
VMHOST=vmh01
scp ~/.ssh/docker_rsa.pub $VMHOST:.ssh/
```



Do the following from the VM host

``` shell
VMID=2000
NAME=d03-test
#IP=10.0.0.62/24
IP="10.0.0.63/24"
GW="10.0.0.1"
DNS="10.0.0.10,10.0.0.11"
SEARCHDOMAIN=asyla.org

# https://cloud.debian.org/images/cloud/
# only 'generic' will work correctly on proxmox
#DEBIAN=debian-12-nocloud-amd64.qcow2
#DEBIAN=debian-12-genericcloud-amd64.qcow2
DEBIAN=debian-12-generic-amd64.qcow2
DEBIANURL=https://cloud.debian.org/images/cloud/bookworm/latest/$DEBIAN

ST_VOL=nas-data1-vm  # location for where to store the image in proxmox

USER=docker
#SOME_PASSWORD=SetPasswordHere  # Used for user login
PUB_SSHKEY=~/.ssh/docker_rsa.pub  # local path on VM host for the public ssh key to use
```



This is only needed the first time (slow)

``` shell
# virt-customize
# from https://austinsnerdythings.com/2021/08/30/how-to-create-a-proxmox-ubuntu-cloud-init-image/
apt install libguestfs-tools -y
```


Obtain and configure the base image to use

``` shell
# clear out old files
cd ~
rm debian-12*.qcow2

# Get the latest image from debian
wget $DEBIANURL


#######################################
# Install software that has to be in place before first boot

TEMP_MOUNT=/mnt/temp
guestunmount $TEMP_MOUNT
rmdir $TEMP_MOUNT
mkdir -p $TEMP_MOUNT

# mount the image for direct access
guestmount -a ~/$DEBIAN -m /dev/sda1 $TEMP_MOUNT

# add an package repo with more recent packages
cat <<EOF >> $TEMP_MOUNT/etc/apt/sources.list.d/debian.sources

Types: deb
URIs: http://http.us.debian.org/debian
Suites: sid
Components: main
EOF

# Install (current) cloud-init
virt-customize -a ~/$DEBIAN --run-command "apt-get update"
virt-customize -a ~/$DEBIAN --run-command "apt-get install -y cloud-init"


# NFS

# iSCSI

# Docker




# cleanup
guestunmount $TEMP_MOUNT
rmdir $TEMP_MOUNT

#######################################


# install qemu client upon first start
virt-customize -a $DEBIAN --install qemu-guest-agent

# Set TZ
virt-customize -a $DEBIAN --timezone "America/Chicago"

# These settings are likely for kubernetes
virt-customize -a $DEBIAN \
  --append-line '/etc/sysctl.d/99-k8s-cni.conf:' \
  --append-line '/etc/sysctl.d/99-k8s-cni.conf:net.bridge.bridge-nf-call-iptables=1' \
  --append-line '/etc/sysctl.d/99-k8s-cni.conf:net.bridge.bridge-nf-call-ip6tables=1'

# Truncating this ensures each clone gets a new machine ID
virt-customize -a $DEBIAN --truncate /etc/machine-id

# update all software upon first start
#virt-customize -a $DEBIAN --update
```


Create and configure the VM in Proxmox

``` shell
qm destroy $VMID
#rm -R /mnt/nas/data1/vm/images/$VMID

# create vm
qm create $VMID \
  --name $NAME \
  --cpu host \
  --machine q35 \
  --memory 25600 \
  --cores 6 \
  --sockets 2 \
  --ostype l26 \
  --numa 1 \
  --onboot 1 `: # Start the VM at boot` \
  --net0 virtio,bridge=vmbr1,firewall=1,tag=100 \
  --agent enabled=1,fstrim_cloned_disks=1,type=virtio `: # Enable Qemu Guest Agent`

# cloud-image specific settings
#qm set $VMID \
#  --citype nocloud `: # linux`

# add the image to the VM
qm importdisk $VMID $DEBIAN $ST_VOL -format qcow2
qm set $VMID \
  --scsihw virtio-scsi-pci \
  --scsi0 $ST_VOL:$VMID/vm-$VMID-disk-0.qcow2

# [resize disks](https://pve.proxmox.com/wiki/Resize_disks)
#qm resize $VMID scsi0 +28G
qm resize $VMID scsi0 64G  

# create the boot image disk
# /mnt/nas/data1/vm/images/2000/vm-2000-cloudinit.qcow2
qm set $VMID \
  --ide2 $ST_VOL:cloudinit \
  --boot c \
  --bootdisk scsi0 \
  --vga serial0 \
  --serial0 socket

# user stuff
qm set $VMID \
  --ciuser $USER \
  --sshkey $PUB_SSHKEY \
`: #  --cipassword $SOME_PASSWORD`
`: # --cicustom "user=local:snippets/user-data.yml"`
# done now dump the user
#qm cloudinit dump $VMID user

# configure networking
qm set $VMID \
`: # --ipconfig0 ip=dhcp` \
  --ipconfig0 ip=$IP,gw=$GW \
  --nameserver $DNS \
  --searchdomain $SEARCHDOMAIN







#qm config $VMID # Display the config
#qm start $VMID && qm terminal $VMID
#qm shutdown $VMID



# turn this into a template
#qm template $VMID



# final cleanup
cd ~
rm $DEBIAN
```



--------------------------------------------------
--------------------------------------------------
old stuff below
--------------------------------------------------
--------------------------------------------------


``` shell
qm create $VMID \
  --name $NAME \
  --sockets 2 \
  --cores 6 \
  --memory 25600 \
  --ostype l26 \
  --scsihw virtio-scsi-pci \
  --bootdisk scsi0 \
  --net0 virtio,bridge=vmbr1,firewall=1,tag=100 \
  --onboot 1 \
  --numa 0 \
  --agent 1,fstrim_cloned_disks=1



qm importdisk $VMID $DEBIAN nas-data1-vm -format qcow2


qm start $VMID
```




## create VM

Create the Alpine Linux VM on Proxmox
[10.12. Managing Virtual Machines with qm](https://pve.proxmox.com/pve-docs/pve-admin-guide.html#_managing_virtual_machines_with_span_class_monospaced_qm_span)

This will create a 1G disk of file and then logically resize it to to 256G but the file will remain at 1G until it fills.  This saves the need to shrink the file later on which dramatically speeds up the process

The [qm.conf](https://pve.proxmox.com/wiki/Manual:_qm.conf) file is located in `/etc/pve/qemu-server/<VMID>.conf`

``` shell
VMID=103
qm create $VMID \
  --name d03 \
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

qm resize $VMID scsi0 64G # [resize disks](https://pve.proxmox.com/wiki/Resize_disks)

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
10.0.0.62
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
adduser -u 1003 -G asyla -g "docker" shepner
```

### doas

``` shell
adduser docker wheel

apk add doas
echo "permit nopass :wheel" >> /etc/doas.conf
```

### SSH

from local workstation, copy over the ssh keys

``` shell
DHOST=d03
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
~/scripts/`hostname -s`/setup/smb.sh
~/scripts/`hostname -s`/setup/nfs.sh
~/scripts/`hostname -s`/setup/iscsi.sh
~/scripts/`hostname -s`/setup/docker.sh

~/update.sh
```

---

!!! WARNING
  Skip this part unless there is a way to mount a local disk across multiple servers.  Or if there are NO databases

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

