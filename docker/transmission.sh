#!/bin/sh
# https://docs.linuxserver.io/images/docker-transmission


# Load the global functions and default environment variables
. ~/scripts/docker/common.sh


# Setup the app specific environment vars
IMAGE=lscr.io/linuxserver/${NAME}
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
appCreateDir ${DOCKERAPPDIR}/watch
appCreateDir ${DOCKERAPPDIR}/downloads
appBackup ${DOCKERDIR} ${NAME} # backup the app


doas docker run --detach --restart=unless-stopped \
  --name ${NAME} \
  --cpus=2 \
  --cpu-shares=768 \
  --env PUID=${DOCKER_UID} \
  --env PGID=${DOCKER_GID} \
  --env TZ=${LOCAL_TZ} \
  --network=${NETWORK} \
  --mount type=bind,src=${CONFIGDIR},dst=/config \
  --mount type=bind,src=${DOCKERAPPDIR}/watch,dst=/watch \
  --mount type=bind,src=${DOCKERAPPDIR}/downloads,dst=/downloads \
  `:  --publish published=9091,target=9091,protocol=tcp,mode=ingress` \
  --publish published=51413,target=51413,protocol=tcp,mode=ingress \
  --publish published=51413,target=51413,protocol=udp,mode=ingress \
  ${IMAGE}

dockerRestartProxy

# enter shell to troubleshoot:
#doas docker exec -it transmission /bin/bash

