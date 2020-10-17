#!/bin/sh
# https://jupyter-docker-stacks.readthedocs.io/en/latest/
# https://jupyter-docker-stacks.readthedocs.io/en/latest/using/common.html

# Notes
# `JUPYTER_ALLOW_INSECURE_WRITES=true` is needed when using a filesystem with SMB because the permissions for the kernel's files show as '0o677' instead of '0o0600'

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
#sudo -u \#${DOCKER_UID} tar -czf ${DOCKER_D1}/${NAME}.tgz -C ${DOCKERDIR} ${NAME}
echo "Backup complete"

sudo docker run --detach --restart=unless-stopped \
  --name ${NAME} \
  --cpu-shares=1024 \
  --env TZ=${LOCAL_TZ} \
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
  --user root \
  --workdir /home/${DOCKER_UNAME}/work \
  --env CHOWN_HOME=yes \
  --publish published=8888,target=8888,protocol=tcp,mode=ingress \
  ${IMAGE}

# docker exec -it ${IMAGE} bash

