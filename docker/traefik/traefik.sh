#!/bin/sh
# [Traefik v2](https://github.com/DoTheEvo/Traefik-v2-examples#1-traefik-routing-to-various-docker-containers) examples


# Load the functions and environment variables
. ~/scripts/docker/common.sh


NAME=traefik
CONFIGDIR=$DOCKER_D2/$NAME/config


# create the dir if needed
if [ ! -d $CONFIGDIR ]; then
  sudo -u \#$DOCKER_UID mkdir -p $CONFIGDIR
fi

sudo -u \#$DOCKER_UID cp ~/scripts/docker/traefik/traefik.yml $CONFIGDIR

dockerNetworkCreate $NETWORK_INTERNET


sudo docker-compose -f ~/scripts/docker/traefik/docker-compose.yml --env-file ~/scripts/docker/common.env pull $NAME
sudo docker-compose -f ~/scripts/docker/traefik/docker-compose.yml --env-file ~/scripts/docker/common.env rm --force --stop $NAME
sudo docker-compose -f ~/scripts/docker/traefik/docker-compose.yml --env-file ~/scripts/docker/common.env up -d $NAME


