#!/bin/sh
# https://docs.linuxserver.io/images/docker-unifi-controller

# [UniFi - Ports Used](https://help.ui.com/hc/en-us/articles/218506997)
# 1900/udp Required for Make controller discoverable on L2 network option
# 3478/udp Unifi STUN port
# 5514 Remote syslog port
# 6789 For mobile throughput test
# 8080 Required for device communication
# 8443 Unifi web admin port
# 8843 Unifi guest portal HTTPS redirect port
# 8880 Unifi guest portal HTTP redirect port
# 10001/udp Required for AP discovery


# Load the global functions and environment variables
. ~/scripts/docker/common.sh


# Setup the app specific environment vars
IMAGE=ghcr.io/linuxserver/${NAME}
DOCKERDIR=${DOCKER_DL} # local disk
#DOCKERDIR=${DOCKER_D1} # NFS attached HDD
#DOCKERDIR=${DOCKER_D2} # NFS attached SSD
DOCKERAPPDIR=${DOCKERDIR}/${NAME}
CONFIGDIR=${DOCKERAPPDIR}/config


# Perform setups/updates as needed
dockerPull ${IMAGE} # fetch the latest image
dockerStopRm ${NAME} # kill the old one
dockerNetworkCreate ${NETWORK} # create the network if needed
appCreateDir ${CONFIGDIR} # create the folder if needed
appBackup ${DOCKERDIR} ${NAME} # backup the app


sudo docker run --detach --restart=unless-stopped \
  --name ${NAME} \
  --cpu-shares=1024 \
  --env PUID=${DOCKER_UID} \
  --env PGID=${DOCKER_GID} \
  --env TZ=${LOCAL_TZ} \
  --mount type=bind,src=${CONFIGDIR},dst=/config \
  --publish published=1900,target=1900,protocol=udp,mode=ingress \
  --publish published=3478,target=3478,protocol=udp,mode=ingress \
  --publish published=5514,target=5514,protocol=udp,mode=ingress \
  --publish published=6789,target=6789,protocol=tcp,mode=ingress \
  --publish published=8080,target=8080,protocol=tcp,mode=ingress \
`:  --publish published=8443,target=8443,protocol=tcp,mode=ingress` \
  --publish published=8843,target=8843,protocol=tcp,mode=ingress \
  --publish published=8880,target=8880,protocol=tcp,mode=ingress \
  --publish published=10001,target=10001,protocol=udp,mode=ingress \
  ${IMAGE}

