#!/bin/sh
# https://github.com/homebridge/homebridge/wiki/Install-Homebridge-on-Docker
# https://github.com/oznu/docker-homebridge
# https://homebridge.io/
#
# Camera stuff:
# https://github.com/seydx/homebridge-camera-ui
#   Uses port 8081 by default
# https://securitycamcenter.com/rtsp-commands-axis-cameras/


# Load the global functions and environment variables
. ~/scripts/docker/common.sh


# Setup the app specific environment vars
IMAGE=oznu/${NAME}:latest
DOCKERDIR=${DOCKER_DL} # local disk
#DOCKERDIR=${DOCKER_D1} # NFS attached HDD
#DOCKERDIR=${DOCKER_D2} # NFS attached SSD
DOCKERAPPDIR=${DOCKERDIR}/${NAME}
CONFIGDIR=${DOCKERAPPDIR}/config


# Perform setups/updates as needed
dockerPull ${IMAGE} # fetch the latest image
dockerStopRm ${NAME} # kill the old one
dockerNetworkCreate ${NETWORK} # create the network if needed
appCreateDir ${DOCKERAPPDIR} # create the folder if needed
#appCreateDir ${CONFIGDIR} # create the folder if needed
appBackup ${DOCKERDIR} ${NAME} # backup the app


doas docker run --detach --restart=unless-stopped \
  --name ${NAME} \
  --cpus=2 \
  --env TZ=${LOCAL_TZ} \
  --env ENABLE_AVAHI=1 \
  --network=${NETWORK} \
`:  --network=host` \
  --mount type=bind,src=${DOCKERAPPDIR},dst=/homebridge \
  --publish published=8581,target=8581,protocol=tcp,mode=ingress \
  --publish published=8081,target=8081,protocol=tcp,mode=ingress \
  ${IMAGE}

dockerRestartProxy

