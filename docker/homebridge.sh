#!/bin/sh
# https://github.com/homebridge/homebridge/wiki/Install-Homebridge-on-Docker
# https://github.com/oznu/docker-homebridge
# https://homebridge.io/
#
# Camera stuff:
# https://github.com/seydx/homebridge-camera-ui
# https://securitycamcenter.com/rtsp-commands-axis-cameras/
# - rtsp://username:password@device-IP-Address/mpeg4/media.amp
# - rtsp://username:password@device-IP-Address/mpeg4/media.amp?camera=<number>
#
# #  Ports:
#  - 8581: Homebridge web UI
#  - 8181: Camera-UI web UI
#  - 51956: Homebridge service
#  - <random>: camera (axis-b8a44f522e4a)




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
  --network=host \
  --mount type=bind,src=${DOCKERAPPDIR},dst=/homebridge \
  ${IMAGE}

dockerRestartProxy


#`:  --network=${NETWORK}` \
#  --publish published=8581,target=8581,protocol=tcp,mode=ingress \
#`:  --publish published=8181,target=8081,protocol=tcp,mode=ingress` \
#  --publish published=8181,target=8181,protocol=tcp,mode=ingress \
#  --publish published=51956,target=51956,protocol=tcp,mode=ingress \

