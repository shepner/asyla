#!/bin/sh
# https://docs.linuxserver.io/images/docker-dillinger



# Load the functions and environment variables
. ~/scripts/docker/common.sh


NAME=`basename "${0}" ".sh"`
IMAGE=ghcr.io/linuxserver/${NAME}
DOCKERDIR=${DOCKER_DL} # Run this locally
DOCKERAPPDIR=${DOCKERDIR}/${NAME}
CONFIGDIR=${DOCKERAPPDIR}/config
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

sudo docker run --detach --restart=unless-stopped \
  --name ${NAME} \
  --cpu-shares=1024 \
  --env PUID=${DOCKER_UID} \
  --env PGID=${DOCKER_GID} \
  --env TZ=${LOCAL_TZ} \
  --mount type=bind,src=${DOCKERAPPDIR},dst=/config \
  --publish published=10080,target=8080,protocol=tcp,mode=ingress \
  ${IMAGE}

