#!/bin/sh
# [Traefik v2](https://github.com/DoTheEvo/Traefik-v2-examples#1-traefik-routing-to-various-docker-containers) examples


# Load the functions and environment variables
. ~/scripts/docker/docker.env


NAME=traefik
CONFIGDIR=$DOCKER_D2/$NAME/config


# create the dir if needed
if [ ! -d $CONFIGDIR ]; then
  sudo -u \#$DOCKER_UID mkdir -p $CONFIGDIR
fi

sudo -u \#$DOCKER_UID cp ~/scripts/docker/traefik/traefik.yml $CONFIGDIR

dockerNetworkCreate $NETWORK_INTERNET


sudo docker-compose -f ~/scripts/docker/traefik/docker-compose.yml --env-file ~/scripts/docker/docker.env pull $NAME
sudo docker-compose -f ~/scripts/docker/traefik/docker-compose.yml --env-file ~/scripts/docker/docker.env rm --force --stop $NAME
sudo docker-compose -f ~/scripts/docker/traefik/docker-compose.yml --env-file ~/scripts/docker/docker.env up -d $NAME





# To stop all containers
#docker stop $(docker ps -q)

#NAME=traefik
#IMAGE=traefik:v2.2
#CONFIGDIR=/mnt/nas/data2/docker/$NAME/config

#sudo -u docker mkdir -p $CONFIGDIR

#wget -O $CONFIGDIR/traefik.yml https://raw.githubusercontent.com/shepner/proxmox-docker/master/docker/traefik/traefik.yml

#sudo docker pull $IMAGE
#sudo docker stop $NAME
#sudo docker rm -v $NAME

#sudo docker run --detach --restart=always \
#  --name $NAME \
#  --cpus=2 \
#  --cpu-shares=1024 \
#  --env PUID=1003 \
#  --env PGID=1000 \
#  --publish published=80,target=80,protocol=tcp,mode=ingress \
#  --publish published=8080,target=8080,protocol=tcp,mode=ingress \
#  --mount type=bind,src=$CONFIGDIR/traefik.yml,dst=/etc/traefik/traefik.yml \
#  $IMAGE
  
  # --cpu-shares=1024 # default job priority
