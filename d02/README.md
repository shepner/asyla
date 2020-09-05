# d02

Docker host running as a Proxmox VM

## Install Ubuntu

install Ubuntu 20.04 the usual way.

provide a static IP address

DNS: 10.0.0.5,208.67.222.222,208.67.220.220

Do NOT setup disk as LVM group

Install OpenSSH

## Fix the UID

First set the permissions of the home dir:

``` shell
sudo chown -R 1001 /home/`id -un`
```

Then change the UID accodingly in the passwd files:

``` shell
sudo vipw
```

Finally, logout and back in again

## Setup ssh keys

Do this from the local workstation:

``` shell
DHOST=d02
ssh-copy-id -i ~/.ssh/shepner_rsa.pub $DHOST

scp ~/.ssh/shepner_rsa $DHOST:.ssh/shepner_rsa
scp ~/.ssh/shepner_rsa.pub $DHOST:.ssh/shepner_rsa.pub
scp ~/.ssh/config $DHOST:.ssh/config
ssh $DHOST "chmod -R 700 ~/.ssh"
```

## Configure the system

``` shell
bash <(curl -s https://raw.githubusercontent.com/shepner/asyla/master/`hostname -s`/update_scripts.sh)

~/scripts/`hostname -s`/setup/userConfig.sh

~/scripts/`hostname -s`/setup/systemConfig.sh

~/scripts/`hostname -s`/setup/nfs.sh

~/scripts/`hostname -s`/setup/smb.sh

~/scripts/`hostname -s`/setup/docker.sh

~/update.sh
```

## Configure Docker Swarm

Run this on the first node:

``` shell
sudo docker swarm init

# for managers
sudo docker swarm join-token manager

# for workers
sudo docker swarm join-token worker
```

Follow the instructions provided and run the command on each of the other nodes as appropriate:

``` shell
sudo docker swarm join --token <TOKEN> <IP>:2377
```

