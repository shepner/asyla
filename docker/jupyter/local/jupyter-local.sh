#!/bin/sh
# https://jupyter-docker-stacks.readthedocs.io/en/latest/
# https://jupyter-docker-stacks.readthedocs.io/en/latest/using/common.html


# Load the functions and environment variables
. ~/scripts/docker/common.sh


NAME=jupyter-local
IMAGE=${NAME}
SOURCE=~/scripts/docker/jupyter/local
DOCKERDIR=${DOCKER_D1}
DOCKERAPPDIR=${DOCKERDIR}/${NAME}
#CONFIGDIR=${DOCKERAPPDIR}/config


# build the container
cd ${SOURCE}
sudo docker build --tag $IMAGE .

#
dockerStopRm ${NAME} # kill the old one
#
# create the dir if needed
if [ ! -d ${DOCKERAPPDIR} ]; then
  sudo -u \#${DOCKER_UID} mkdir -p ${DOCKERAPPDIR}
fi
#
echo "Making a backup"
sudo -u \#${DOCKER_UID} tar -czf ${DOCKER_D1}/${NAME}.tgz -C ${DOCKERDIR} ${NAME}
echo "Backup complete"

sudo docker run --detach --restart=unless-stopped \
  --name ${NAME} \
  --cpu-shares=1024 \
  --env NB_UID=${DOCKER_UID} \
  --env NB_USER=${DOCKER_UNAME} \
  --env NB_GID=${DOCKER_GID} \
  --env NB_GROUP=${DOCKER_GNAME} \
  --env CHOWN_HOME=yes \
  --env GRANT_SUDO=yes \
  --env GEN_CERT=yes \
  --env JUPYTER_ENABLE_LAB=yes \
  --env RESTARTABLE=yes \
  --env TZ=${LOCAL_TZ} \
  --mount type=bind,src=${DOCKERAPPDIR},dst=/home/${DOCKER_UNAME} \
  --publish published=8888,target=8888,protocol=tcp,mode=ingress \
  ${IMAGE}

# docker exec -it ${IMAGE} bash

