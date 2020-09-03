#!/bin/sh
# https://docs.linuxserver.io/images/docker-calibre

# 8080: Calibre desktop gui. ctrl-alt-shift to access the clipboard
# 8081: Calibre webserver gui.

# [Customizing calibre](https://manual.calibre-ebook.com/customize.html)
# Environment variables:
# * CALIBRE_OVERRIDE_DATABASE_PATH - allows you to specify the full path to metadata.db. Using this variable you can have metadata.db be in a location other than the library folder. Useful if your library folder is on a networked drive that does not support file locking.


# Load the functions and environment variables
. ~/scripts/docker/common.sh


NAME=calibre
IMAGE=linuxserver/calibre
CONFIGDIR=$DOCKER_DL/$NAME/config


dockerPull $IMAGE # fetch the latest image
dockerStopRm $NAME # kill the old one


# create the dir if needed
if [ ! -d $CONFIGDIR ]; then
  sudo -u \#$DOCKER_UID mkdir -p $CONFIGDIR
fi


# direct access
#sudo docker run --detach --restart=always \
#  --name $NAME \
#  --cpus=2 \
#  --cpu-shares=1024 \
#  --env PUID=$DOCKER_UID \
#  --env PGID=$DOCKER_GID \
#  --env TZ=$LOCAL_TZ \
#  --env CALIBRE_OVERRIDE_DATABASE_PATH="/config/metadata.db" \
#  --mount type=bind,src=$CONFIGDIR,dst=/config \
#  --mount type=bind,src=$DATA1/media,dst=/media \
#  --publish published=6080,target=8080,protocol=tcp,mode=ingress \
#  --publish published=6081,target=8081,protocol=tcp,mode=ingress \
#  $IMAGE

# access via traefik
dockerNetworkCreate $NETWORK_INTERNET
sudo docker run --detach --restart=always \
  --name $NAME \
  --cpus=2 \
  --cpu-shares=1024 \
  --env PUID=$DOCKER_UID \
  --env PGID=$DOCKER_GID \
  --env TZ=$LOCAL_TZ \
  --env CALIBRE_OVERRIDE_DATABASE_PATH="/config/metadata.db" \
  --mount type=bind,src=$CONFIGDIR,dst=/config \
  --mount type=bind,src=$DATA1/media,dst=/media \
  --network=$NETWORK_INTERNET \
  --label traefik.enable=true \
  --label traefik.http.routers.$NAME.rule=Host\(\`$NAME.$MY_DOMAIN\`\) \
  --label traefik.http.routers.$NAME.entrypoints=web \
  --label traefik.http.services.$NAME.loadbalancer.server.port=8080 \
  $IMAGE

