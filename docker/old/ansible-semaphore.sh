#!/bin/sh
# https://github.com/ansible-semaphore/semaphores


# Load the global functions and environment variables
. ~/scripts/docker/common.sh


# Setup the app specific environment vars
IMAGE=semaphoreui/semaphore:latest
DOCKERDIR=${DOCKER_DL} # local disk
#DOCKERDIR=${DOCKER_D1} # NFS attached HDD
#DOCKERDIR=${DOCKER_D2} # NFS attached SSD
DOCKERAPPDIR=${DOCKERDIR}/${NAME}
CONFIGDIR=${DOCKERAPPDIR}/config


# Perform setups/updates as needed
dockerPull ${IMAGE} # fetch the latest image
dockerStopRm ${NAME} # kill the old one
dockerNetworkCreate ${NETWORK} # create the network if needed
appCreateDir ${DOCKERAPPDIR} # create the folder if needed
appCreateDir ${CONFIGDIR} # create the folder if needed
appCreateDir ${DOCKERAPPDIR}/lib # create the folder if needed
appBackup ${DOCKERDIR} ${NAME} # backup the app


doas docker run --detach --restart=unless-stopped \
  --name ${NAME} \
`:  --cpus=2` \
`:  --cpu-shares=1024` `# default job priority` \
`:  --env PUID=${DOCKER_UID}` \
`:  --env PGID=${DOCKER_GID}` \
`:  --env TZ=${LOCAL_TZ}` \
  --network=${NETWORK} \
  --env SEMAPHORE_DB_DIALECT: bolt
  --env SEMAPHORE_ADMIN_PASSWORD: changeme
  --env SEMAPHORE_ADMIN_NAME: admin
  --env SEMAPHORE_ADMIN_EMAIL: admin@localhost
  --env SEMAPHORE_ADMIN: admin
  --mount type=bind,src=${CONFIGDIR},dst=/etc/semaphore `# config.json location` \
  --mount type=bind,src=${DOCKERAPPDIR}/lib,dst=/var/lib/semaphore `# database.boltdb location (Not required if using mysql or postgres)` \
  --publish published=3000,target=3000,protocol=tcp,mode=ingress \
  ${IMAGE}

#dockerRestartProxy


