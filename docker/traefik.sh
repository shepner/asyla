#!/bin/sh
# [Traefik v2](https://github.com/DoTheEvo/Traefik-v2-examples#1-traefik-routing-to-various-docker-containers) examples


# Load the functions and environment variables
. ~/scripts/docker/docker.env


NAME=traefik
IMAGE=traefik:v2.2
CONFIGDIR=$DOCKER_D2/$NAME/config


dockerPull $IMAGE # fetch the latest image
dockerStopRm $NAME # kill the old one


# create the dir if needed
if [ ! -d $CONFIGDIR ]; then
  sudo -u \#$DOCKER_UID mkdir -p $CONFIGDIR
fi

sudo -u \#$DOCKER_UID cp ~/scripts/docker/traefik.yml $CONFIGDIR

dockerNetworkCreate $NETWORK_INTERNET

sudo docker run --detach --restart=always \
  --name $NAME \
  --cpus=2 \
  --cpu-shares=1024 \
  --env PUID=$DOCKER_UID \
  --env PGID=$DOCKER_GID \
  --env TZ=$LOCAL_TZ \
  --mount type=bind,src=$CONFIGDIR/traefik.yml,dst=/etc/traefik/traefik.yml:ro \
  --mount type=bind,src=/var/run/docker.sock,dst=/var/run/docker.sock:ro \
  --publish published=80,target=80,protocol=tcp,mode=ingress \
  --publish published=8080,target=8080,protocol=tcp,mode=ingress \
  --network $NETWORK_INTERNET \
  $IMAGE

