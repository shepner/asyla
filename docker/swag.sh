#!/bin/sh
# https://docs.linuxserver.io/images/docker-swag

# https://blog.linuxserver.io/2020/08/21/introducing-swag/
# https://docs.linuxserver.io/general/swag


# Load the global functions and environment variables
. ~/scripts/docker/common.sh


# Setup the app specific environment vars
IMAGE=ghcr.io/linuxserver/${NAME}
DOCKERDIR=${DOCKER_DL} # local disk
#DOCKERDIR=${DOCKER_D1} # NFS attached HDD
#DOCKERDIR=${DOCKER_D2} # NFS attached SSD
DOCKERAPPDIR=${DOCKERDIR}/${NAME}
CONFIGDIR=${DOCKERAPPDIR}/config


# Perform setups/updates as needed
dockerPull ${IMAGE} # fetch the latest image
dockerStopRm ${NAME} # kill the old one
dockerNetworkCreate ${NETWORK} # create the network if needed
appCreateDir ${CONFIGDIR} # create the folder if needed
appBackup ${DOCKERDIR} ${NAME} # backup the app


sudo docker create \
  --name ${NAME} \
`:  --cpu-shares=1024` \
  --env PUID=${DOCKER_UID} \
  --env PGID=${DOCKER_GID} \
  --env TZ=${LOCAL_TZ} \
  --cap-add=NET_ADMIN \
  --env URL=${MY_DOMAIN} \
  --env SUBDOMAINS=booksonic,calibre,dillinger,jupyter,unifi,www, \
  --env VALIDATION=dns \
  --env DNSPLUGIN=cloudflare \
  --env EMAIL=${MY_EMAIL} \
  --env ONLY_SUBDOMAINS=false \
  --env STAGING=false \
  --mount type=bind,src=${CONFIGDIR},dst=/config \
  --publish published=80,target=80,protocol=tcp,mode=ingress \
  --publish published=443,target=443,protocol=tcp,mode=ingress \
  ${IMAGE}

# Needed per proxied app on this host
# [Multiple subnets in Docker container](https://stackoverflow.com/a/39393229)
sudo docker network connect booksonic_net ${NAME}
sudo docker network connect calibre_net ${NAME}
sudo docker network connect dillinger_net ${NAME}
sudo docker network connect heimdall_net ${NAME}
sudo docker network connect jupyter_net ${NAME}
sudo docker network connect unifi-controller_net ${NAME}

# Dont forget to also setup a config file per app:
# /docker/swag/config/nginx/proxy-confs

sudo docker start ${NAME}

