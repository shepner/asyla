#!/bin/sh
# https://github.com/shepner/Docker-DNSmasq

# Combined DNS and DHCP server

# WARNING: This runs with privledged rights

NAME=dnsmasq
IMAGE=shepner/dnsmasq
BASEPATH=/mnt/nas/data2/docker/$NAME

sudo mkdir -p $BASEPATH/config
#sudo wget -O $BASEPATH/config/dnsmasq_dhcp.conf https://raw.githubusercontent.com/shepner/Docker-DNSmasq/master/dnsmasq.conf
#sudo wget -O $BASEPATH/config/dnsmasq.conf https://raw.githubusercontent.com/shepner/Docker-DNSmasq/master/dnsmasq.conf
#sudo wget -O $BASEPATH/resolv.conf https://raw.githubusercontent.com/shepner/Docker-DNSmasq/master/resolv.conf

sudo docker pull $IMAGE
sudo docker stop $NAME
sudo docker rm -v $NAME

sudo docker run --detach --restart=always \
  --name=$NAME \
  --cpus=2 \
  --cpu-shares=2048 \
  --privileged \
  --env DNSMASQ_CONF=/mnt/config/dnsmasq_combined.conf \
  --mount type=bind,src=$BASEPATH,dst=/mnt \
  --network host \
  $IMAGE
