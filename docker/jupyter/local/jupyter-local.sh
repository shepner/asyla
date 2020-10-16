#!/bin/sh
# https://jupyter-docker-stacks.readthedocs.io/en/latest/

# Load the functions and environment variables
. ~/scripts/docker/common.sh


NAME=jupyter-local
IMAGE=${NAME}
SOURCE=~/scripts/docker/jupyter/local
DOCKERDIR=${DOCKER_D1}
DOCKERAPPDIR=${DOCKERDIR}/${NAME}
CONFIGDIR=${DOCKERAPPDIR}/config


# build the container
cd ${SOURCE}
build --tag $IMAGE .

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
  --mount type=bind,src=${CONFIGDIR},dst=/config \
  --publish published=8888,target=8888,protocol=tcp,mode=ingress \
  ${IMAGE}

