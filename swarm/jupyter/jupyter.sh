#!/bin/sh
# https://jupyter-docker-stacks.readthedocs.io/en/latest/
# https://jupyter-docker-stacks.readthedocs.io/en/latest/using/common.html

# Notes
# `JUPYTER_ALLOW_INSECURE_WRITES=true` is needed when using a filesystem with SMB because the permissions for the kernel's files show as '0o677' instead of '0o0600'


# Load the global functions and environment variables
. ~/scripts/docker/common.sh


# Setup the app specific environment vars
IMAGE=${NAME}
DOCKERDIR=${DOCKER_DL} # local disk
#DOCKERDIR=${DOCKER_D1} # NFS attached HDD
#DOCKERDIR=${DOCKER_D2} # NFS attached SSD
DOCKERAPPDIR=${DOCKERDIR}/${NAME}
CONFIGDIR=${DOCKERAPPDIR}/config

SOURCE=~/scripts/docker/${NAME} # location of the Dockerfile
WORKDIR=${DOCKER_D1}/${NAME}/work # location of the notebooks


# Perform setups/updates as needed
#dockerPull ${IMAGE} # fetch the latest image
# build the container
cd ${SOURCE} && sudo docker build --tag $IMAGE .
dockerStopRm ${NAME} # kill the old one
dockerNetworkCreate ${NETWORK} # create the network if needed
#appCreateDir ${CONFIGDIR} # create the config folder if needed
appCreateDir ${DOCKERAPPDIR}/work
appBackup ${DOCKERDIR} ${NAME} # backup the app
appBackup ${DOCKER_D1}/${NAME} ${NAME} # backup the app


sudo docker run --detach --restart=unless-stopped \
  --name ${NAME} \
`:  --cpu-shares=1024` \
  --env TZ=${LOCAL_TZ} \
  --network=${NETWORK} \
  --env NB_UID=${DOCKER_UID} \
  --env NB_USER=${DOCKER_UNAME} \
  --env NB_GID=${DOCKER_GID} \
  --env NB_GROUP=${DOCKER_GNAME} \
  --env GRANT_SUDO=yes \
  --env GEN_CERT=yes \
  --env JUPYTER_ENABLE_LAB=yes \
  --env RESTARTABLE=yes \
  --env JUPYTER_ALLOW_INSECURE_WRITES=true \
  --mount type=bind,src=${DOCKERAPPDIR},dst=/home/${DOCKER_UNAME} \
  --mount type=bind,src=${WORKDIR},dst=/home/${DOCKER_UNAME}/work \
  --user root \
  --workdir /home/${DOCKER_UNAME}/work \
  --env CHOWN_HOME=yes \
`:  --publish published=8888,target=8888,protocol=tcp,mode=ingress` \
  ${IMAGE}


dockerRestartProxy

# To troubleshoot:
# docker exec -it ${IMAGE} bash

