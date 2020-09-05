#!/bin/sh


# Load the functions and environment variables
. ~/scripts/docker/common.sh


NAME=envoy
IMAGE=envoyproxy/envoy:v1.15.0
DOCKERDIR=${DOCKER_DL}


DOCKERAPPDIR=${DOCKERDIR}/${NAME}
CONFIGDIR=${DOCKERAPPDIR}/config
#
# create the dir if needed
if [ ! -d ${CONFIGDIR} ]; then
  sudo -u \#${DOCKER_UID} mkdir -p ${CONFIGDIR}
fi


#build the image
sudo -u \#${DOCKER_UID} cp ~/scripts/docker/envoy/envoy.yaml ${CONFIGDIR}
sudo -u \#${DOCKER_UID} cp ~/scripts/docker/envoy/Dockerfile ${CONFIGDIR}
cd ${CONFIGDIR}
sudo docker build -t envoy:v1 .




#
#dockerPull ${IMAGE} # fetch the latest image
#dockerStopRm ${NAME} # kill the old one
#
#
#echo "Making a backup"
#sudo -u \#${DOCKER_UID} tar -czf ${DOCKER_D1}/${NAME}.tgz -C ${DOCKERDIR} ${NAME}
#echo "Backup complete"


# direct access
sudo docker run --detach --restart=always \
  --name ${NAME} \
  --env ENVOY_UID=${DOCKER_UID} \
  --env ENVOY_GID=${DOCKER_GID} \
  --publish published=10000,target=10000,protocol=tcp,mode=ingress \
  --publish published=9901,target=9901,protocol=tcp,mode=ingress \
  envoy:v1


