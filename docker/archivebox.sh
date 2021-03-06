#!/bin/sh
# https://archivebox.io

# $1 values:
# "": normal opertion
# "new": start fresh


# Examples:
#sudo docker exec -it archivebox bash
# sudo docker exec -it archivebox su archivebox archivebox --help
# sudo docker exec -it archivebox su archivebox archivebox schedule --help
# sudo docker exec -it archivebox su archivebox archivebox add --depth=0 < ./Safari_Bookmarks.html
# sudo docker exec -it archivebox su archivebox archivebox manage createsuperuser


# Load the global functions and environment variables
. ~/scripts/docker/common.sh


# Setup the app specific environment vars
IMAGE=archivebox/${NAME}
DOCKERDIR=${DOCKER_DL} # local disk
#DOCKERDIR=${DOCKER_D1} # NFS attached HDD
#DOCKERDIR=${DOCKER_D2} # NFS attached SSD
DOCKERAPPDIR=${DOCKERDIR}/${NAME}
CONFIGDIR=${DOCKERAPPDIR}/config


if [ -z ${1} ]; then
  SWITCH="none" # set a value so the rest of the script doesnt complain
else
  SWITCH=${1}
fi


# Perform setups/updates as needed
dockerPull ${IMAGE} # fetch the latest image
dockerStopRm ${NAME} # kill the old one
if [ ${SWITCH} = "new" ]; then # start with a fresh config folder
  sudo rm -R ${DOCKERAPPDIR}
fi
dockerNetworkCreate ${NETWORK} # create the network if needed
#appCreateDir ${CONFIGDIR} # create the folder if needed
appCreateDir ${DOCKERAPPDIR}/archive
appCreateDir ${DOCKER_D1}/${NAME}/archive
appBackup ${DOCKERDIR} ${NAME} # backup the app


if [ ${SWITCH} = "new" ]; then
  # Init the DB (also needed if/when the schema changes)
  sudo docker run -v ${DOCKERAPPDIR}:/data -v ${DOCKER_D1}/${NAME}/archive:/data/archive -it ${IMAGE} init
  # Create an admin account
  sudo docker run -v ${DOCKERAPPDIR}:/data -it ${IMAGE} manage createsuperuser
fi


# Set default file permissions
sudo docker run -v ${DOCKERAPPDIR}:/data -it ${IMAGE} config --set OUTPUT_PERMISSIONS=775
# Permit public access to the pages
sudo docker run -v ${DOCKERAPPDIR}:/data -it ${IMAGE} config --set PUBLIC_SNAPSHOTS=True
# Turn off public access to the top level page
sudo docker run -v ${DOCKERAPPDIR}:/data -it ${IMAGE} config --set PUBLIC_INDEX=False
# Prevent viewing the files within the directory
sudo docker run -v ${DOCKERAPPDIR}:/data -it ${IMAGE} config --set PUBLIC_ADD_VIEW=False
# Tell the bots to go away
echo "User-agent: * Disallow: /" | sudo -u \#${DOCKER_UID} tee ${DOCKERAPPDIR}/robots.txt > /dev/null


sudo docker run --detach --restart=unless-stopped \
  --name ${NAME} \
`:  --cpus=2` \
`:  --cpu-shares=1024` `# default job priority` \
`:  --env PUID=${DOCKER_UID}` \
`:  --env PGID=${DOCKER_GID}` \
  --env TZ=${LOCAL_TZ} \
  --network=${NETWORK} \
  --mount type=bind,src=${DOCKERAPPDIR},dst=/data \
  --mount type=bind,src=${DOCKER_D1}/${NAME}/archive,dst=/data/archive \
`:  --publish published=8000,target=8000,protocol=tcp,mode=ingress` \
  ${IMAGE}

dockerRestartProxy

