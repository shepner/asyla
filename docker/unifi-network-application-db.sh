#!/bin/sh
# https://docs.linuxserver.io/images/docker-unifi-network-application/#setting-up-your-external-database

# this needs to run on the same network as 'unifi-network-application'
# Only mount `init-mongo.js` the first time to initialize the DB


# Load the global functions and environment variables
. ~/scripts/docker/common.sh


# Setup the app specific environment vars
#IMAGE=lscr.io/linuxserver/${NAME}
IMAGE=docker.io/mongo:4
DOCKERDIR=${DOCKER_DL} # local disk
#DOCKERDIR=${DOCKER_D1} # NFS attached HDD
#DOCKERDIR=${DOCKER_D2} # NFS attached SSD
DOCKERAPPDIR=${DOCKERDIR}/${NAME}
#CONFIGDIR=${DOCKERAPPDIR}/config


# Perform setups/updates as needed
dockerPull ${IMAGE} # fetch the latest image
dockerStopRm ${NAME} # kill the old one
#dockerNetworkCreate ${NETWORK} # create the network if needed
dockerNetworkCreate unifi-network-application_net # create the network if needed
#appCreateDir ${CONFIGDIR} # create the folder if needed
appCreateDir ${DOCKERAPPDIR}/db # create the folder if needed
appBackup ${DOCKERDIR} ${NAME} # backup the app


doas docker run --detach --restart=unless-stopped \
  --name ${NAME} \
  --env PUID=${DOCKER_UID} \
  --env PGID=${DOCKER_GID} \
  --env TZ=${LOCAL_TZ} \
  --mount type=bind,src=${DOCKERAPPDIR}/db,dst=/data/db \
`:  --mount type=bind,src=${DOCKERAPPDIR}/init-mongo.js,dst=/docker-entrypoint-initdb.d/init-mongo.js,readonly` \
  ${IMAGE}

#dockerRestartProxy

