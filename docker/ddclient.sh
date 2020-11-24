#!/bin/sh
# https://docs.linuxserver.io/images/docker-dillinger


# Load the global functions and environment variables
. ~/scripts/docker/common.sh


# Setup the app specific environment vars
NAME=`basename "${0}" ".sh"`
IMAGE=ghcr.io/linuxserver/${NAME}
DOCKERDIR=${DOCKER_D2}
DOCKERAPPDIR=${DOCKERDIR}/${NAME}
CONFIGDIR=${DOCKERAPPDIR}/config
NETWORK=${NAME}_net


# Perform setups/updates as needed
dockerPull ${IMAGE} # fetch the latest image
dockerStopRm ${NAME} # kill the old one
dockerNetworkCreate ${NETWORK} # create the network if needed
appCreateDir ${CONFIGDIR} # create the config folder if needed
appBackup ${DOCKERDIR} ${NAME} # backup the app


#  --cpu-shares=1024 \# default job priority
sudo docker run --detach --restart=unless-stopped \
  --name ${NAME} \
  --cpus=2 \
  --env PUID=${DOCKER_UID} \
  --env PGID=${DOCKER_GID} \
  --env TZ=${LOCAL_TZ} \
  --network=${NETWORK} \
  --mount type=bind,src=${CONFIGDIR},dst=/config \
  ${IMAGE}

