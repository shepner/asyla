#!/bin/sh
# https://docs.linuxserver.io/images/docker-sonarr


# Load the global functions and default environment variables
. ~/scripts/docker/common.sh


# Setup the app specific environment vars
IMAGE=ghcr.io/linuxserver/${NAME}
DOCKERDIR=/mnt/nas/data2/docker_01
#DOCKERDIR=${DOCKER_DL} # local disk
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
  --cpus=2 \
  --cpu-shares=768 \
  --env PUID=${DOCKER_UID} \
  --env PGID=${DOCKER_GID} \
  --env TZ=${LOCAL_TZ} \
  --network=${NETWORK} \
`:  --dns 10.0.0.5` \
`:  --publish published=8989,target=8989,protocol=tcp,mode=ingress` \
  --mount type=bind,src=/etc/localtime,dst=/etc/localtime,readonly=1 \
  --mount type=bind,src=${CONFIGDIR},dst=/config \
  --mount type=bind,src=/mnt/nas/data1/media/Videos,dst=/tv \
`:  --mount type=bind,src=/mnt/nas/data1/docker/transmission/downloads/complete,dst=/downloads` \
  --mount type=bind,src=/mnt/nas/data2/docker_01/transmission/downloads/complete,dst=/downloads \
  ${IMAGE}

dockerRestartProxy

