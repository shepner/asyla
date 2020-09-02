#!/bin/sh
# https://docs.linuxserver.io/images/docker-foldingathome

NAME=foldingathome
IMAGE=linuxserver/foldingathome
CONFIGDIR=/mnt/nas/data2/docker/$NAME/config

sudo -u docker mkdir -p $CONFIGDIR

sudo docker pull $IMAGE
sudo docker stop $NAME
sudo docker rm -v $NAME

sudo docker run --detach --restart=always \
  --name $NAME \
  --cpus=16 \
  --cpu-shares=256 \
  --env PUID=1003 \
  --env PGID=1000 \
  --env TZ="America/Chicago" \
  --publish published=7396,target=7396,protocol=tcp,mode=ingress \
  --mount type=bind,src=$CONFIGDIR,dst=/config \
  $IMAGE
  
  # --cpu-shares=1024 # default job priority
