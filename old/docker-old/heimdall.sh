#!/bin/sh
# https://docs.linuxserver.io/images/docker-heimdall

# 80: web interface
# 443: web interface


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
sleep 10 # because this takes some time to shut down
dockerNetworkCreate ${NETWORK} # create the network if needed
appCreateDir ${CONFIGDIR} # create the folder if needed
appBackup ${DOCKERDIR} ${NAME} # backup the app


# direct access
sudo docker run --detach --restart=unless-stopped \
  --name ${NAME} \
  --cpus=2 \
`:  --cpu-shares=1024` \
  --env PUID=${DOCKER_UID} \
  --env PGID=${DOCKER_GID} \
  --env TZ=${LOCAL_TZ} \
  --network=${NETWORK} \
`:  --publish published=80,target=80,protocol=tcp,mode=ingress` \
`:  --publish published=443,target=443,protocol=tcp,mode=ingress` \
  --mount type=bind,src=${CONFIGDIR},dst=/config \
  ${IMAGE}

dockerRestartProxy

