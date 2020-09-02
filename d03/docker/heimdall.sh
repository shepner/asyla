#!/bin/sh
# https://docs.linuxserver.io/images/docker-heimdall
# https://heimdall.site/

# http://<hostname>:9080

CUID=1003
CGID=1000
TIMEZONE="America/Chicago"
NAME=heimdall
CPUS=2
CSHARES=512 # job priority: 1024 = default
BASEPATH=/data1/docker/$NAME

sudo -u docker mkdir -p $BASEPATH/config

sudo docker run --detach \
  --name $NAME \
  --cpus="$CPUS" \
  --cpu-shares=$CSHARES \
  --env PUID=$CUID \
  --env PGID=$CGID \
  --env TZ=$TIMEZONE \
  --publish published=9080,target=80,protocol=tcp,mode=ingress \
  --publish published=9443,target=443,protocol=tcp,mode=ingress \
  --mount type=bind,src=$BASEPATH/config,dst=/config \
  linuxserver/heimdall
  
