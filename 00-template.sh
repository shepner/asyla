#!/bin/sh
# https://docs.linuxserver.io/images/docker-codimd
# https://hedgedoc.org
# https://github.com/hedgedoc/hedgedoc/tree/HEAD/docs


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
appCreateDir ${DOCKERAPPDIR} # create the folder if needed
#appCreateDir ${CONFIGDIR} # create the folder if needed
appBackup ${DOCKERDIR} ${NAME} # backup the app


doas docker run --detach --restart=unless-stopped \
  --name ${NAME} \
  --cpus=2 \
`:  --cpu-shares=1024` `# default job priority` \
  --env PUID=${DOCKER_UID} \
  --env PGID=${DOCKER_GID} \
  --env TZ=${LOCAL_TZ} \
  --network=${NETWORK} \
  --env CMD_DOMAIN=${NAME}.${MY_DOMAIN} \
  --env CMD_PROTOCOL_USESSL=true \
  --mount type=bind,src=${DOCKERAPPDIR},dst=/config \
`:  --publish published=3000,target=3000,protocol=tcp,mode=ingress` \
  ${IMAGE}

dockerRestartProxy

