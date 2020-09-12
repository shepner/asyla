#!/bin/sh
# https://docs.linuxserver.io/images/docker-sonarr

NAME=sonarr
IMAGE=linuxserver/sonarr
BASEDIR=/docker/$NAME

sudo -u docker mkdir -p $BASEDIR/config
#sudo -u docker mkdir -p $BASEDIR/tv
#sudo -u docker mkdir -p $BASEDIR/downloads

sudo docker pull $IMAGE
sudo docker stop $NAME
sudo docker rm -v $NAME

sudo docker run --detach --restart=always \
  --name $NAME \
  --cpus=2 \
  --cpu-shares=768 \
  --env PUID=1003 \
  --env PGID=1000 \
  --env TZ="America/Chicago" \
  --dns 10.0.0.5 \
  --publish published=8989,target=8989,protocol=tcp,mode=ingress \
  --mount type=bind,src=/etc/localtime,dst=/etc/localtime,readonly=1 \
  --mount type=bind,src=$BASEDIR/config,dst=/config \
  --mount type=bind,src=/mnt/nas/data1/media/Videos,dst=/tv \
  --mount type=bind,src=/mnt/nas/data1/docker/transmission/downloads/complete,dst=/downloads \
  $IMAGE
  
  # --cpu-shares=1024 # default job priority
