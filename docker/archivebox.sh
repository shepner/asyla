#!/bin/sh
# https://archivebox.io

# Instructions for how to schedule jobs
#sudo docker exec -it ${NAME} archivebox schedule --help


# Load the global functions and environment variables
. ~/scripts/docker/common.sh


# Setup the app specific environment vars
IMAGE=archivebox/${NAME}
DOCKERDIR=${DOCKER_DL} # local disk
#DOCKERDIR=${DOCKER_D1} # NFS attached HDD
#DOCKERDIR=${DOCKER_D2} # NFS attached SSD
DOCKERAPPDIR=${DOCKERDIR}/${NAME}
CONFIGDIR=${DOCKERAPPDIR}/config


# Initial setup tasks
if [ ${1} ]; then
  dockerStopRm ${NAME} # kill the old one
  sudo rm -R ${DOCKERAPPDIR}
fi


# Perform setups/updates as needed
dockerPull ${IMAGE} # fetch the latest image
dockerStopRm ${NAME} # kill the old one
dockerNetworkCreate ${NETWORK} # create the network if needed
#appCreateDir ${CONFIGDIR} # create the folder if needed
appCreateDir ${DOCKERAPPDIR}/archive
appCreateDir ${DOCKER_D1}/${NAME}/archive
appBackup ${DOCKERDIR} ${NAME} # backup the app


echo "User-agent: * Disallow: /" | sudo -u \#${DOCKER_UID} tee -a ${DOCKERAPPDIR}/robots.txt > /dev/null


# Initial setup tasks
if [ ${1} ]; then
  sudo docker run -v ${DOCKERAPPDIR}:/data -it ${IMAGE} init
  sudo docker run -v ${DOCKERAPPDIR}:/data -it ${IMAGE} add 'https://example.com'
  sudo docker run -v ${DOCKERAPPDIR}:/data -it ${IMAGE} manage createsuperuser
fi


sudo docker run --detach --restart=unless-stopped \
  --name ${NAME} \
`:  --cpus=2` \
`:  --cpu-shares=1024` `# default job priority` \
`:  --env PUID=${DOCKER_UID}` \
`:  --env PGID=${DOCKER_GID}` \
`:  --env TZ=${LOCAL_TZ}` \
  --network=${NETWORK} \
  --mount type=bind,src=${DOCKERAPPDIR},dst=/data \
  --mount type=bind,src=${DOCKER_D1}/${NAME}/archive,dst=/data/archive \
`:  --publish published=8000,target=8000,protocol=tcp,mode=ingress` \
  ${IMAGE}

