#!/bin/sh
# https://docs.linuxserver.io/images/docker-jackett


# Load the global functions and default environment variables
. ~/scripts/docker/common.sh


# Setup the app specific environment vars
IMAGE=ghcr.io/linuxserver/${NAME}
#DOCKERDIR=${DOCKER_DL} # local disk
#DOCKERDIR=${DOCKER_D1} # NFS attached HDD
DOCKERDIR=${DOCKER_D2} # NFS attached SSD
DOCKERAPPDIR=${DOCKERDIR}/${NAME}
CONFIGDIR=${DOCKERAPPDIR}/config


# Perform setups/updates as needed
dockerPull ${IMAGE} # fetch the latest image
dockerStopRm ${NAME} # kill the old one
dockerNetworkCreate ${NETWORK} # create the network if needed
appCreateDir ${CONFIGDIR} # create the config folder if needed
appCreateDir ${DOCKERAPPDIR}/downloads
appBackup ${DOCKERDIR} ${NAME} # backup the app


sudo docker run --detach --restart=unless-stopped \
  --name ${NAME} \
  --cpus=2 \
  --cpu-shares=768 \
  --env PUID=${DOCKER_UID} \
  --env PGID=${DOCKER_GID} \
  --env TZ=${LOCAL_TZ} \
  --network=${NETWORK} \
  --env AUTO_UPDATE=true \
`:  --publish published=9117,target=9117,protocol=tcp,mode=ingress` \
  --mount type=bind,src=${CONFIGDIR},dst=/config \
  --mount type=bind,src=${DOCKERAPPDIR}/downloads,dst=/downloads \
  $IMAGE

