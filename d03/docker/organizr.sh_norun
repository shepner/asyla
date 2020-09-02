#!/bin/sh
# https://docs.linuxserver.io/images/docker-organizr
# https://organizr.app/

# http://<hostname>:9983

CUID=1003
CGID=1000
TIMEZONE="America/Chicago"
NAME=organizr
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
  --publish published=9983,target=80,protocol=tcp,mode=ingress \
  --mount type=bind,src=$BASEPATH/config,dst=/config \
  linuxserver/organizr
  
