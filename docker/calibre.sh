#!/bin/sh
# https://docs.linuxserver.io/images/docker-calibre

# 6080(8080) Calibre desktop gui. ctrl-alt-shift to access the clipboard
# 6081(8081) Calibre webserver gui.

# [Customizing calibre](https://manual.calibre-ebook.com/customize.html)
# Environment variables
# CALIBRE_OVERRIDE_DATABASE_PATH - allows you to specify the full path to metadata.db. Using this variable you can have metadata.db be in a location other than the library folder. Useful if your library folder is on a networked drive that does not support file locking.

NAME=calibre
IMAGE=linuxserver/calibre
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
  --env CALIBRE_OVERRIDE_DATABASE_PATH="/config/metadata.db" \
  --mount type=bind,src=$CONFIGDIR,dst=/config \
  --mount type=bind,src=/mnt/nas/data1/media,dst=/media \
  --publish published=6080,target=8080,protocol=tcp,mode=ingress \
  --publish published=6081,target=8081,protocol=tcp,mode=ingress \
  $IMAGE
  
  # --cpu-shares=1024 # default job priority
