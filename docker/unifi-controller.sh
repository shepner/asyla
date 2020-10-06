#!/bin/sh
# https://docs.linuxserver.io/images/docker-unifi-controller

# [UniFi - Ports Used](https://help.ui.com/hc/en-us/articles/218506997)
# 3478/udp Unifi STUN port
# 10001/udp Required for AP discovery
# 8080 Required for device communication
# 8443 Unifi web admin port
# 1900/udp Required for Make controller discoverable on L2 network option
# 8843 Unifi guest portal HTTPS redirect port
# 8880 Unifi guest portal HTTP redirect port
# 6789 For mobile throughput test
# 5514 Remote syslog port


# Load the functions and environment variables
. ~/scripts/docker/common.sh


NAME=unifi-controller
IMAGE=linuxserver/unifi-controller
DOCKERDIR=${DOCKER_DL} # Run this locally
DOCKERAPPDIR=${DOCKERDIR}/${NAME}
CONFIGDIR=${DOCKERAPPDIR}/config
#
dockerPull ${IMAGE} # fetch the latest image
dockerStopRm ${NAME} # kill the old one
#
# create the dir if needed
if [ ! -d ${CONFIGDIR} ]; then
  sudo -u \#${DOCKER_UID} mkdir -p ${CONFIGDIR}
fi
#
echo "Making a backup"
sudo -u \#${DOCKER_UID} tar -czf ${DOCKER_D1}/${NAME}.tgz -C ${DOCKERDIR} ${NAME}
echo "Backup complete"

sudo docker run --detach --restart=unless-stopped \
  --name ${NAME} \
  --cpu-shares=1024 \
  --env PUID=${DOCKER_UID} \
  --env PGID=${DOCKER_GID} \
  --env TZ=${LOCAL_TZ} \
  --mount type=bind,src=${CONFIGDIR},dst=/config \
  --publish published=3478,target=3478,protocol=udp,mode=ingress \
  --publish published=5514,target=5514,protocol=udp,mode=ingress \
  --publish published=8080,target=8080,protocol=tcp,mode=ingress \
  --publish published=8443,target=8443,protocol=tcp,mode=ingress \
  --publish published=8880,target=8880,protocol=tcp,mode=ingress \
  --publish published=8843,target=8843,protocol=tcp,mode=ingress \
  --publish published=6789,target=6789,protocol=tcp,mode=ingress \
  --publish published=10001,target=10001,protocol=udp,mode=ingress \
  ${IMAGE}


