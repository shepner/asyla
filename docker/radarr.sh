#!/bin/sh
# https://docs.linuxserver.io/images/docker-sonarr


# Load the global functions and default environment variables
. ~/scripts/docker/common.sh


# Setup the app specific environment vars
IMAGE=lscr.io/linuxserver/${NAME}:latest
DOCKERDIR=${DOCKER_DL} # local disk
#DOCKERDIR=${DOCKER_D1} # NFS attached HDD
#DOCKERDIR=${DOCKER_D2} # NFS attached SSD
DOCKERAPPDIR=${DOCKERDIR}/${NAME}
CONFIGDIR=${DOCKERAPPDIR}/config


# Perform setups/updates as needed
dockerPull ${IMAGE} # fetch the latest image
dockerStopRm ${NAME} # kill the old one
dockerNetworkCreate ${NETWORK} # create the network if needed
appCreateDir ${CONFIGDIR} # create the config folder if needed
appBackup ${DOCKERDIR} ${NAME} # backup the app


doas docker run --detach --restart=unless-stopped \
  --name ${NAME} \
`:  --cpus=2` \
`:  --cpu-shares=768` \
  --env PUID=${DOCKER_UID} \
  --env PGID=${DOCKER_GID} \
  --env TZ=${LOCAL_TZ} \
  --network=${NETWORK} \
`:  --publish published=7878,target=7878,protocol=tcp,mode=ingress` \
  --mount type=bind,src=${CONFIGDIR},dst=/config \
  --mount type=bind,src=/mnt/nas/data1/media/Videos,dst=/movies \
  --mount type=bind,src=/mnt/docker/transmission/downloads/complete,dst=/downloads \
  ${IMAGE}

#dockerRestartProxy

