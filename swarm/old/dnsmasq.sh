#!/bin/sh
# https://github.com/shepner/Docker-DNSmasq

# Combined DNS and DHCP server

# WARNING: This runs with privledged rights


# Load the global functions and default environment variables
. ~/scripts/docker/common.sh


# Setup the app specific environment vars
#IMAGE=shepner/${NAME}
IMAGE=${NAME}
#DOCKERDIR=${DOCKER_DL} # local disk
#DOCKERDIR=${DOCKER_D1} # NFS attached HDD
DOCKERDIR=${DOCKER_D2} # NFS attached SSD
DOCKERAPPDIR=${DOCKERDIR}/${NAME}
CONFIGDIR=${DOCKERAPPDIR}/config


# fetch/build image
sudo docker build --tag ${NAME}:latest github.com/shepner/Docker-DNSmasq

# Perform setups/updates as needed
#dockerPull ${IMAGE} # fetch the latest image
dockerStopRm ${NAME} # kill the old one
dockerNetworkCreate ${NETWORK} # create the network if needed
appCreateDir ${CONFIGDIR} # create the folder if needed
appBackup ${DOCKERDIR} ${NAME} # backup the app


# Initial setup stuff
#sudo wget -O $CONFIGDIR/dnsmasq_dhcp.conf https://raw.githubusercontent.com/shepner/Docker-DNSmasq/master/dnsmasq.conf
#sudo wget -O $CONFIGDIR/dnsmasq.conf https://raw.githubusercontent.com/shepner/Docker-DNSmasq/master/dnsmasq.conf
#sudo wget -O $DOCKERAPPDIR/resolv.conf https://raw.githubusercontent.com/shepner/Docker-DNSmasq/master/resolv.conf


sudo docker run --detach --restart=always \
  --name=${NAME} \
  --cpus=2 \
  --cpu-shares=2048 \
  --privileged `# needed for DHCP` \
  --mount type=bind,src=${DOCKERAPPDIR},dst=/mnt \
  --env DNSMASQ_CONF=/mnt/config/dnsmasq_combined.conf \
  --network host \
  ${IMAGE}

