#!/bin/sh
# https://archivebox.io

# $1 values:
# "": normal opertion
# "new": start fresh
# "init": reinitialize the DB


# Instructions for how to schedule jobs
#sudo docker exec -it ${NAME} archivebox schedule --help

# example of how to import a file manually:
#sudo docker exec -it archivebox bash
#su archivebox
#archivebox add --depth=0 < ./Safari_Bookmarks.html

# Load the global functions and environment variables
. ~/scripts/docker/common.sh


# Setup the app specific environment vars
IMAGE=archivebox/${NAME}
DOCKERDIR=${DOCKER_DL} # local disk
#DOCKERDIR=${DOCKER_D1} # NFS attached HDD
#DOCKERDIR=${DOCKER_D2} # NFS attached SSD
DOCKERAPPDIR=${DOCKERDIR}/${NAME}
CONFIGDIR=${DOCKERAPPDIR}/config


if [ -n ${1} ]; then
  1="none" # set a value so the rest of the script doesnt complain
fi


# Initial setup tasks
if [ ${1} == "new" ]; then
  dockerStopRm ${NAME} # kill the old one
  #sudo rm -R ${DOCKERAPPDIR}
fi


# Perform setups/updates as needed
dockerPull ${IMAGE} # fetch the latest image
dockerStopRm ${NAME} # kill the old one
dockerNetworkCreate ${NETWORK} # create the network if needed
#appCreateDir ${CONFIGDIR} # create the folder if needed
appCreateDir ${DOCKERAPPDIR}/archive
appCreateDir ${DOCKER_D1}/${NAME}/archive
appBackup ${DOCKERDIR} ${NAME} # backup the app


echo "User-agent: * Disallow: /" | sudo -u \#${DOCKER_UID} tee ${DOCKERAPPDIR}/robots.txt > /dev/null


# Initial setup tasks
if [ ${1} == "init" ]; then
  sudo docker run -v ${DOCKERAPPDIR}:/data -v ${DOCKER_D1}/${NAME}/archive:/data/archive -it ${IMAGE} init
fi

if [ ${1} == "new" ]; then
  sudo docker run -v ${DOCKERAPPDIR}:/data -v ${DOCKER_D1}/${NAME}/archive:/data/archive -it ${IMAGE} init
  sudo docker run -v ${DOCKERAPPDIR}:/data -it ${IMAGE} config --set OUTPUT_PERMISSIONS=775
  sudo docker run -v ${DOCKERAPPDIR}:/data -it ${IMAGE} config --set PUBLIC_SNAPSHOTS=True
  sudo docker run -v ${DOCKERAPPDIR}:/data -it ${IMAGE} config --set PUBLIC_INDEX=True
  sudo docker run -v ${DOCKERAPPDIR}:/data -it ${IMAGE} config --set PUBLIC_ADD_VIEW=True
  #sudo docker run -v ${DOCKERAPPDIR}:/data -it ${IMAGE} manage createsuperuser
fi


sudo docker run --detach --restart=unless-stopped \
  --name ${NAME} \
`:  --cpus=2` \
`:  --cpu-shares=1024` `# default job priority` \
`:  --env PUID=${DOCKER_UID}` \
`:  --env PGID=${DOCKER_GID}` \
  --env TZ=${LOCAL_TZ} \
  --network=${NETWORK} \
`:  --mount type=bind,src=/etc/localtime,dst=/etc/localtime,readonly=1` \
  --mount type=bind,src=${DOCKERAPPDIR},dst=/data \
  --mount type=bind,src=${DOCKER_D1}/${NAME}/archive,dst=/data/archive \
`:  --publish published=8000,target=8000,protocol=tcp,mode=ingress` \
  ${IMAGE}

dockerRestartProxy

