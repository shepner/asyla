#!/bin/sh
# [Traefik v2](https://github.com/DoTheEvo/Traefik-v2-examples#1-traefik-routing-to-various-docker-containers) examples


# Load the functions and environment variables
. ~/scripts/docker/common.sh


NAME=traefik
CONFIGDIR=$DOCKER_D2/$NAME/config


# create the dir if needed
if [ ! -d $CONFIGDIR ]; then
  sudo -u \#$DOCKER_UID mkdir -p $CONFIGDIR/dynamic
fi


dockerNetworkCreate $NETWORK_INTERNET


# docker swarm
sudo docker stack rm ${NAME}
sudo docker stack deploy --compose-file ~/scripts/docker/traefik/docker-compose.yml ${NAME}


