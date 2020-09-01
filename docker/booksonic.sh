#!/bin/sh
# https://docs.linuxserver.io/images/docker-booksonic

# 4040(4040) web interface

NAME=booksonic
IMAGE=linuxserver/booksonic
CONFIGDIR=/docker/$NAME/config

sudo -u docker mkdir -p $CONFIGDIR

sudo docker pull $IMAGE
sudo docker stop $NAME
sudo docker rm -v $NAME

sudo docker run --detach --restart=always \
  --name $NAME \
  --cpus=2 \
  --cpu-shares=1024 \
  --env PUID=1003 \
  --env PGID=1000 \
  --env TZ="America/Chicago" \
  --publish published=4040,target=4040,protocol=tcp,mode=ingress \
  --mount type=bind,src=$CONFIGDIR,dst=/config \
  --mount type=bind,src=/mnt/nas/data1/media/Audiobook,dst=/audiobooks \
  $IMAGE
  
# --cpu-shares=1024 # default job priority
  

#  -e CONTEXT_PATH=url-base \
#  -v </path/to/podcasts>:/podcasts \
#  -v </path/to/othermedia>:/othermedia \
