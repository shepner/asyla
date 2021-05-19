#!/bin/sh
# http://tdarr.io/docs/installation/docker
# http://tdarr.io/docs/installation/getting-started
# This is for the tdar server


# Load the global functions and default environment variables
. ~/scripts/docker/common.sh


# Setup the app specific environment vars
IMAGE=haveagitgat/${NAME}
#DOCKERDIR=${DOCKER_DL} # local disk
DOCKERDIR=${DOCKER_D1} # NFS attached HDD
#DOCKERDIR=${DOCKER_D2} # NFS attached SSD
DOCKERAPPDIR=${DOCKERDIR}/${NAME}
CONFIGDIR=${DOCKERAPPDIR}/configs


# Perform setups/updates as needed
dockerPull ${IMAGE} # fetch the latest image
dockerStopRm ${NAME} # kill the old one
dockerNetworkCreate ${NETWORK} # create the network if needed
appCreateDir ${CONFIGDIR} # create the config folder if needed
appCreateDir ${DOCKERAPPDIR}/server
appCreateDir ${DOCKERAPPDIR}/logs
appCreateDir ${DOCKERAPPDIR}/transcode_cache
#appBackup ${DOCKERDIR} ${NAME} # backup the app


sudo docker run --detach --restart=unless-stopped \
  --name ${NAME} \
`:  --cpus=2` \
`:  --cpu-shares=768` \
  --env TZ=${LOCAL_TZ} \
  --env PUID=${DOCKER_UID} \
  --env PGID=${DOCKER_GID} \
  --mount type=bind,src=${DOCKERAPPDIR}/server,dst=/app/server \
  --mount type=bind,src=${CONFIGDIR},dst=/configs \
  --mount type=bind,src=${DOCKERAPPDIR}/logs,dst=/app/logs \
  --mount type=bind,src=${DOCKERAPPDIR}/transcode_cache,dst=/tmp \
  --mount type=bind,src=/mnt/nas/data1/media/Videos/00-Handbrake,dst=/media \
  --env serverIP=0.0.0.0 \
  --env serverPort=8266 \
  --env webUIPort=8265 \
  --network=${NETWORK} \
  --publish published=8265,target=8265,protocol=tcp,mode=ingress \
  --publish published=8266,target=8266,protocol=tcp,mode=ingress \
`:  --env NVIDIA_DRIVER_CAPABILITIES=all` \
`:  --env NVIDIA_VISIBLE_DEVICES=all` \
`:  --gpus=all` \
`:  --device=/dev/dri:/dev/dri` \
  --log-opt max-size=10m \
  --log-opt max-file=5 \
  ${IMAGE}

