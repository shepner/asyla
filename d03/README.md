# Install Notes

## Install server from console

1. have a physical server suitable to run [Docker](https://www.docker.com/) containers, VMs (via [KVM](https://www.linux-kvm.org/)), while using ZFS

    * ZFS data pool should be 4TB mirrored and is dedicated to docker/VMs
    * separate boot/swap drive(s)

2. Download/install [Ubuntu Server 20.04.01 LTS](https://ubuntu.com/download/server/thank-you?version=20.04.1&architecture=amd64)

    * use fixed IP address, install OpenSSH

## User account stuff

### Remove what little bits of pesky security we have

``` shell
echo "`id -un` ALL=(ALL) NOPASSWD: ALL" | sudo EDITOR='tee -a' visudo
```

### Setup ssh keys

Do this from the local workstation:

``` shell
DHOST=d03
ssh-copy-id -i ~/.ssh/shepner_rsa.pub $DHOST
scp ~/.ssh/shepner_rsa $DHOST:.ssh/shepner_rsa
scp ~/.ssh/shepner_rsa.pub $DHOST:.ssh/shepner_rsa.pub
scp ~/.ssh/config $DHOST:.ssh/config
ssh $DHOST "chmod -R 700 ~/.ssh"
```

### Fix groups

``` shell
sudo groupmod `id -un` -n asyla
```

### Forward email

``` shell
echo "`id -un`@asyla.org" > ~/.forward
echo "`id -un`@asyla.org" | sudo tee -a /root/.forward
```

## Initial config items

### Patch the system

``` shell
cat > ~/update.sh << EOF
sudo apt-get update && sudo apt-get -y upgrade && sudo apt-get -y dist-upgrade && sudo apt -y autoremove
EOF
chmod 754 ~/update.sh
~/update.sh
```

### Set the timezone

``` shell
sudo timedatectl set-timezone America/Chicago
```

### Install net-tools

``` shell
sudo apt-get update
sudo apt-get install -y net-tools
```

### [Disable the local dns listener](https://mmoapi.com/post/how-to-disable-dnsmasq-port-53-listening-on-ubuntu-18-04) (might require a reboot)

``` shell
#sudo netstat -tulnp | grep 53
echo 'DNSStubListener=no' | sudo tee --append /etc/systemd/resolved.conf
sudo systemctl daemon-reload
sudo systemctl restart systemd-resolved.service
#sudo netstat -tulnp | grep 53

sudo rm /etc/resolv.conf
sudo sh -c 'cat > /etc/resolv.conf << EOF
search asyla.org
nameserver 10.0.0.71
nameserver 208.67.222.222
nameserver 208.67.220.220
EOF'
```

### Disk monitoring

``` shell
sudo apt update
sudo apt install -y smartmontools

systemctl status smartd
```

## [OpenZFS](https://openzfs.github.io/openzfs-docs/Getting%20Started/Ubuntu/index.html#installation)

Install utilities:

``` shell
sudo apt update
sudo apt -y install zfsutils-linux
```

Run `sudo zpool import -f data1` to import an existing pool, otherwise do the following

Show what disks are on the system:

``` shell
sudo lsblk
```

Create a ZFS mirror using the 2 spare drives:

``` shell
sudo zpool create data1 mirror /dev/sdb /dev/sdc
```

Create the datasets

``` shell
sudo zfs create data1/docker
sudo zfs create data1/vm
```

### Data replication

[Creating and Destroying ZFS Snapshots](https://docs.oracle.com/cd/E19253-01/819-5461/gbcya/index.html)

create an initial set of snapshots to work with

``` shell
sudo zfs snapshot data1/docker@auto-`date +"%Y-%m-%d_%H-%M"`
sudo zfs snapshot data1/vm@auto-`date +"%Y-%m-%d_%H-%M"`
zfs list -t snapshot
#sudo zfs destroy data1/vm@n03_20200808_165344
```

Schedule the creation of snapshots

``` shell
(
echo "PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin" 
echo "# take snapshot every 6 hours"
echo '0 */6 * * * root zfs snapshot data1/vm@auto-`date +"%Y-%m-%d_%H-%M"`'
echo '0 */6 * * * root zfs snapshot data1/docker@auto-`date +"%Y-%m-%d_%H-%M"`'
) | sudo tee /etc/cron.d/zfs-snapshot
```

Enable ssh login for root

``` shell
echo "PermitRootLogin yes" | sudo tee -a /etc/ssh/sshd_config
sudo systemctl restart sshd
```

Do this part on FreeNAS:

1. Storage > Pools > <pool> > Add Dataset
   Create a new dataset named `<hostname>-<poolname>`
   Create another dataset within called `<poolname>` for each
2. System > Generate Keypairs
   Create/generate key for the host
   Add the public key to the new host

``` shell
sudo vi /root/.ssh/authorized_keys
```
    
3. System > SSH Connections
   Add a new connection for the host using the key
   Discover remote host key, then save
4. Tasks > Replication Tasks
   Create a replication job per dataset
   Keep the data for 2 days
   Replicate every */6 hours
   Save then go back in and check "Replicate from scratch if incremental is not possible"

## setup NFS

``` shell
sudo apt update
sudo apt-get install -y nfs-common
```

Setup mounts
<not sure how much of this is really needed>

``` shell
sudo mkdir -p /mnt/nas/data1/iso
echo "nas:/mnt/data1/iso /mnt/nas/data1/iso nfs rw 0 0" | sudo tee --append /etc/fstab

sudo mkdir -p /mnt/nas/data1/docker
echo "nas:/mnt/data1/docker /mnt/nas/data1/docker nfs rw 0 0" | sudo tee --append /etc/fstab
sudo mkdir -p /mnt/nas/data2/docker
echo "nas:/mnt/data2/docker /mnt/nas/data2/docker nfs rw 0 0" | sudo tee --append /etc/fstab

sudo mkdir -p /mnt/nas/data1/vm
echo "nas:/mnt/data1/vm /mnt/nas/data1/vm nfs rw 0 0" | sudo tee --append /etc/fstab
sudo mkdir -p /mnt/nas/data2/vm
echo "nas:/mnt/data2/vm /mnt/nas/data2/vm nfs rw 0 0" | sudo tee --append /etc/fstab

sudo mkdir -p /mnt/nas/data1/media
echo "nas:/mnt/data1/media /mnt/nas/data1/media nfs rw 0 0" | sudo tee --append /etc/fstab

sudo mount -a
```

## [Docker](https://www.docker.com/)

### Create docker service account

``` shell
sudo adduser --home /home/docker --uid 1003 --gid 1000 --shell /bin/bash docker

sudo gpasswd -a docker sudo
```

### [Install Docker Engine on Ubuntu](https://docs.docker.com/engine/install/ubuntu/):

``` shell
# Update the apt package index and install packages to allow apt to use a repository over HTTPS:
sudo apt-get update

sudo apt-get install -y \
    apt-transport-https \
    ca-certificates \
    curl \
    gnupg-agent \
    software-properties-common

# Add Docker’s official GPG key:
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo apt-key add -

# Use the following command to set up the stable repository
sudo add-apt-repository \
   "deb [arch=amd64] https://download.docker.com/linux/ubuntu \
   $(lsb_release -cs) \
   stable"

# INSTALL DOCKER ENGINE
# Update the apt package index, and install the latest version of Docker Engine and containerd, or go to the next step to install a specific version:
sudo apt-get update
sudo apt-get install -y docker-ce docker-ce-cli containerd.io
```

### Install [Docker Compose](https://docs.docker.com/compose/install/)

``` shell
sudo curl -L "https://github.com/docker/compose/releases/download/1.26.2/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
sudo chmod 755 /usr/local/bin/docker-compose
```

## [KVM](https://help.ubuntu.com/community/KVM/Installation)

Install Necessary Packages

``` shell
sudo apt update
sudo apt-get -y install qemu-kvm libvirt-daemon-system libvirt-clients bridge-utils
```

Add Users to Groups:

``` shell
sudo adduser `id -un` libvirt
sudo adduser `id -un` kvm
```

Be sure to logout/login again

``` shell
logout
```

Verify Installation:

``` shell
virsh list --all
```

Instructions for what to do with this: https://help.ubuntu.com/community/KVM

### GUI management


#### [virt-manager](https://virt-manager.org/):

Best option unless can find something better.
WARNING: This will install X onto the console of the server!

Install [virt-manager](https://virt-manager.org/) which is a (the?) KVM GUI, [a window manager, and VNC](https://www.digitalocean.com/community/tutorials/how-to-install-and-configure-vnc-on-ubuntu-20-04):

``` shell
# select the default options when prompted
#sudo apt-get -y install virt-manager xfce4 xfce4-goodies tightvncserver
sudo apt-get -y install virt-manager xfce4 tightvncserver
```

VNC startup script:

``` shell
cat > ~/.vnc/xstartup << EOF
#!/bin/bash
xrdb $HOME/.Xresources
startxfce4 &
virt-manager &
EOF
chmod 754 ~/.vnc/xstartup
```

Set the VNC password:

``` shell
vncserver

vncserver -kill :1
```

Note that `vncpasswd` can be used to change the password later

Setup and run VNC as a service:

``` shell
sudo sh -c 'cat > /etc/systemd/system/vncserver@.service << EOF
[Unit]
Description=Start TightVNC server at startup
After=syslog.target network.target

[Service]
Type=forking
User=shepner
Group=asyla
WorkingDirectory=/home/shepner

PIDFile=/home/shepner/.vnc/%H:%i.pid
ExecStartPre=-/usr/bin/vncserver -kill :%i > /dev/null 2>&1
#ExecStart=/usr/bin/vncserver -depth 24 -geometry 1280x800 -localhost :%i
ExecStart=/usr/bin/vncserver -depth 24 -geometry 2048x1280 :%i
ExecStop=/usr/bin/vncserver -kill :%i

[Install]
WantedBy=multi-user.target
EOF'

# Make the system aware of the new unit file
sudo systemctl daemon-reload
# Enable the unit file
sudo systemctl enable vncserver@1.service
# Start the service
sudo systemctl start vncserver@1
# Verify that it started
#sudo systemctl status vncserver@1
```

The VNC URL is: `vnc://<hostname>:5901`

#### Other (generally worse) options:

* [Cockpit](https://cockpit-project.org/)
  Avoid: installed fine but very limited VM administration and the "fixes" to make the app work with Umbuntu broke the system
* [oVirt](https://ovirt.org/) Nope.  Requires Cockpit
* [Kimchi](https://github.com/kimchi-project/kimchi): sounds promising but couldnt get it to install (Python 2 vs 3 issues) and doesnt seem to be very active
* Proxmox VE: cant tell how to just install only the app
* [WebVirtMgr](http://retspen.github.io/): sounds promising but requires effort
* [mistio/mist-ce](https://github.com/mistio/mist-ce/releases/) large, difficult, and not all that great
* [Virtlyst](https://github.com/cutelyst/Virtlyst/wiki/Running-with-Docker) broken and hasnt been updated in 1+ yrs

