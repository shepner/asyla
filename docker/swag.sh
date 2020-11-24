#!/bin/sh
# https://docs.linuxserver.io/images/docker-swag

# https://blog.linuxserver.io/2020/08/21/introducing-swag/
# https://docs.linuxserver.io/general/swag


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
sleep 10
sudo -u \#${DOCKER_UID} tar -czf ${DOCKER_D1}/${NAME}.tgz -C ${DOCKERDIR} ${NAME}
echo "Backup complete"


sudo docker create \
  --name ${NAME} \
  --cpu-shares=1024 \
  --env PUID=${DOCKER_UID} \
  --env PGID=${DOCKER_GID} \
  --env TZ=${LOCAL_TZ} \
  --cap-add=NET_ADMIN \
  --env URL=asyla.org \
  --env SUBDOMAINS=www, \
  --env VALIDATION=dns \
  --env DNSPLUGIN=cloudflare \
  --env EMAIL=shepner@asyla.org \
  --env ONLY_SUBDOMAINS=false \
  --env STAGING=false \
  --mount type=bind,src=${CONFIGDIR},dst=/config \
  --publish published=80,target=80,protocol=tcp,mode=ingress \
  --publish published=443,target=443,protocol=tcp,mode=ingress \
  ${IMAGE}

# Needed per app (along with a config file)
# https://stackoverflow.com/a/39393229
sudo docker network connect calibre_net ${NAME}
sudo docker network connect dillinger_net ${NAME}

sudo docker start ${NAME}

