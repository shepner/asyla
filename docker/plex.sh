#!/bin/sh
# https://docs.linuxserver.io/images/docker-plex


# Load the global functions and environment variables
. ~/scripts/docker/common.sh


# Setup the app specific environment vars
IMAGE=ghcr.io/linuxserver/${NAME}
#DOCKERDIR=${DOCKER_DL} # local disk
DOCKERDIR=/mnt/docker # local disk
#DOCKERDIR=${DOCKER_D1} # NFS attached HDD
#DOCKERDIR=${DOCKER_D2} # NFS attached SSD
DOCKERAPPDIR=${DOCKERDIR}/${NAME}
CONFIGDIR=${DOCKERAPPDIR}/plexmediaserver


# Perform setups/updates as needed
dockerPull ${IMAGE} # fetch the latest image
dockerStopRm ${NAME} # kill the old one
#dockerNetworkCreate ${NETWORK} # create the network if needed
appCreateDir ${DOCKERAPPDIR} # create the folder if needed
#appCreateDir ${CONFIGDIR} # create the folder if needed
appBackup ${DOCKERDIR} ${NAME} # backup the app


doas docker run --detach --restart=unless-stopped \
  --name ${NAME} \
  --env PUID=${DOCKER_UID} \
  --env PGID=${DOCKER_GID} \
  --env TZ=${LOCAL_TZ} \
  --env VERSION=latest \
  --env PLEX_CLAIM= `#optional` \
  --env DOCKER_MODS=linuxserver/mods:plex-absolute-hama \
  --network=host \
  --env CMD_DOMAIN=${NAME}.${MY_DOMAIN} \
  --env CMD_PROTOCOL_USESSL=true \
  --mount type=bind,src=${CONFIGDIR},dst=/config \
  --mount type=bind,src=/mnt/nas/data1/media,dst=/mnt/nas/data1/media \
`:  --publish published=32400,target=32400,protocol=tcp,mode=ingress` \
  ${IMAGE}:latest

#dockerRestartProxy

