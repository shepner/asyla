#!/bin/sh
# [Traefik v2](https://github.com/DoTheEvo/Traefik-v2-examples#1-traefik-routing-to-various-docker-containers) examples


# Load the functions and environment variables
. ~/scripts/docker/common.sh


NAME=traefik
CONFIGDIR=${DOCKER_D2}/${NAME}/config


# create the dir if needed
if [ ! -d ${CONFIGDIR} ]; then
  sudo -u \#${DOCKER_UID} mkdir -p ${CONFIGDIR}
fi

# Copy the Traefik config file
sudo -u \#${DOCKER_UID} cp ~/scripts/docker/${NAME}/${NAME}.yaml $DOCKER_D2/$NAME

dockerNetworkCreate ${NETWORK_INTERNET}



sudo docker-compose -f ~/scripts/docker/traefik/docker-compose.yaml --env-file ~/scripts/docker/common.env pull $NAME
sudo docker-compose -f ~/scripts/docker/traefik/docker-compose.yaml --env-file ~/scripts/docker/common.env rm --force --stop $NAME
sudo docker-compose -f ~/scripts/docker/traefik/docker-compose.yaml --env-file ~/scripts/docker/common.env up -d $NAME




