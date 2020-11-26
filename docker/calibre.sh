#!/bin/sh
# https://docs.linuxserver.io/images/docker-calibre

# 8080: Calibre desktop gui. ctrl-alt-shift to access the clipboard
# 8081: Calibre webserver
# 3389: RDP of Calibre desktop

# [Customizing calibre](https://manual.calibre-ebook.com/customize.html)
# Environment variables:
# * CALIBRE_OVERRIDE_DATABASE_PATH - allows you to specify the full path to metadata.db. Using this variable you can have metadata.db be in a location other than the library folder. Useful if your library folder is on a networked drive that does not support file locking.


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
appCreateDir ${CONFIGDIR} # create the folder if needed
appBackup ${DOCKERDIR} ${NAME} # backup the app


sudo docker run --detach --restart=always \
  --name ${NAME} \
  --cpus=2 \
`:  --cpu-shares=1024` \
  --env PUID=${DOCKER_UID} \
  --env PGID=${DOCKER_GID} \
  --env TZ=${LOCAL_TZ} \
  --network=${NETWORK} \
  --env CALIBRE_OVERRIDE_DATABASE_PATH="/config/metadata.db" \
  --mount type=bind,src=${CONFIGDIR},dst=/config \
  --mount type=bind,src=${DATA1}/media,dst=/media \
  --publish published=6080,target=8080,protocol=tcp,mode=ingress \
`:  --publish published=6081,target=8081,protocol=tcp,mode=ingress` \
  ${IMAGE}

