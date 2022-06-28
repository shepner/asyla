#!/bin/sh
# https://docs.linuxserver.io/images/docker-booksonic

# 4040 web interface


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
appCreateDir ${CONFIGDIR} # create the config folder if needed
appBackup ${DOCKERDIR} ${NAME} # backup the app


sudo docker run --detach --restart=always \
  --name ${NAME} \
  --cpus=2 \
`:  --cpu-shares=1024 ``# default job priority`\
  --env PUID=${DOCKER_UID} \
  --env PGID=${DOCKER_GID} \
  --env TZ=${LOCAL_TZ} \
  --network=${NETWORK} \
  --mount type=bind,src=${CONFIGDIR},dst=/config \
  --mount type=bind,src=${DATA1}/media/Audiobook,dst=/audiobooks \
`:  --publish published=4040,target=4040,protocol=tcp,mode=ingress `\
  ${IMAGE}

dockerRestartProxy

