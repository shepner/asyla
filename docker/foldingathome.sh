#!/bin/sh
# https://docs.linuxserver.io/images/docker-foldingathome

# 7396: web management interface


# Load the functions and environment variables
. ~/scripts/docker/common.sh


NAME=foldingathome
IMAGE=linuxserver/foldingathome
DOCKERDIR=${DOCKER_D2}


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
sudo -u \#${DOCKER_UID} tar -czf ${DOCKERAPPDIR}.tgz -C ${DOCKERDIR} ${NAME}
echo "Backup complete"


# direct access
#sudo docker run --detach --restart=always \
#  --name ${NAME} \
#  --cpus=16 \
#  --cpu-shares=256 \
#  --env PUID=${DOCKER_UID} \
#  --env PGID=${DOCKER_GID} \
#  --env TZ=${LOCAL_TZ} \
#  --publish published=7396,target=7396,protocol=tcp,mode=ingress \
#  --mount type=bind,src=${CONFIGDIR},dst=/config \
#  ${IMAGE}

# access via traefik
# https://github.com/DoTheEvo/Traefik-v2-examples
# https://stackoverflow.com/questions/59830648/traefik-multiple-port-bindings-for-the-same-host-v2
dockerNetworkCreate ${NETWORK_INTERNET}
sudo docker run --detach --restart=always \
  --name ${NAME} \
  --cpus=16 \
  --cpu-shares=256 \
  --env PUID=${DOCKER_UID} \
  --env PGID=${DOCKER_GID} \
  --env TZ=${LOCAL_TZ} \
  --mount type=bind,src=${CONFIGDIR},dst=/config \
  --network=${NETWORK_INTERNET} \
  --label traefik.enable=true \
  --label traefik.http.routers.${NAME}_web.rule=Host\(\`${NAME}.${MY_DOMAIN}\`\) \
  --label traefik.http.routers.${NAME}_web.entrypoints=http \
  --label traefik.http.routers.${NAME}_web.service=${NAME}_web_svc \
  --label traefik.http.services.${NAME}_web_svc.loadbalancer.server.port=7396 \
  ${IMAGE}


