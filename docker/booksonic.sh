#!/bin/sh
# https://docs.linuxserver.io/images/docker-booksonic

# 4040 web interface


# Load the functions and environment variables
. ~/scripts/docker/common.sh


NAME=`basename "${0}" ".sh"`
IMAGE=ghcr.io/linuxserver/${NAME}
DOCKERDIR=${DOCKER_DL} # Run this locally
DOCKERAPPDIR=${DOCKERDIR}/${NAME}
CONFIGDIR=${DOCKERAPPDIR}/config
NETWORK=${NAME}_net
#
dockerPull ${IMAGE} # fetch the latest image
dockerStopRm ${NAME} # kill the old one
#
# create the dir if needed
if [ ! -d ${CONFIGDIR} ]; then
  sudo -u \#${DOCKER_UID} mkdir -p ${CONFIGDIR}
fi
#
echo "Making a backup"
sudo -u \#${DOCKER_UID} tar -czf ${DOCKER_D1}/${NAME}.tgz -C ${DOCKERDIR} ${NAME}
echo "Backup complete"

# create the network if needed
dockerNetworkCreate ${NETWORK}

#  --cpu-shares=1024 \# default job priority
#  --publish published=4040,target=4040,protocol=tcp,mode=ingress \
sudo docker run --detach --restart=always \
  --name ${NAME} \
  --cpus=2 \
  --env PUID=${DOCKER_UID} \
  --env PGID=${DOCKER_GID} \
  --env TZ=${LOCAL_TZ} \
  --network=${NETWORK} \
  --mount type=bind,src=${CONFIGDIR},dst=/config \
  --mount type=bind,src=${DATA1}/media/Audiobook,dst=/audiobooks \
  ${IMAGE}


