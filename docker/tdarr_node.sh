#!/bin/sh
# http://tdarr.io/docs/installation/docker


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
appCreateDir ${DOCKERAPPDIR}/watch
appCreateDir ${DOCKERAPPDIR}/downloads
#appBackup ${DOCKERDIR} ${NAME} # backup the app


sudo docker run --detach --restart=unless-stopped \
  --name ${NAME} \
`:  --cpus=2` \
`:  --cpu-shares=768` \
  --mount type=bind,src=${CONFIGDIR},dst=/configs \
  --mount type=bind,src=${DOCKERAPPDIR}/logs,dst=/app/logs \
  --mount type=bind,src=${DOCKERAPPDIR}/transcode_cache,dst=/tmp \
  --mount type=bind,src=/mnt/nas/data1/media/Videos/00-Handbrake,dst=/media \
  --env nodeID=MyFirstTdarrNode \
  --env nodeIP=0.0.0.0 \
  --env nodePort=8267 \
  --env serverIP=0.0.0.0 \
  --env serverPort=8266 \
  --env TZ=${LOCAL_TZ} \
  --env PUID=${DOCKER_UID} \
  --env PGID=${DOCKER_GID} \
  --env NVIDIA_DRIVER_CAPABILITIES=all \
  --env NVIDIA_VISIBLE_DEVICES=all \
  --gpus=all \
  --device=/dev/dri:/dev/dri \
  --log-opt max-size=10m \
  --log-opt max-file=5 \


  --network bridge \
  --publish published=8267,target=8267,protocol=tcp,mode=ingress \
  ${IMAGE}











  --network=${NETWORK} \

