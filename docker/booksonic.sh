#!/bin/sh
# https://docs.linuxserver.io/images/docker-booksonic

# 4040 web interface


# Load the functions and environment variables
. ~/scripts/docker/common.sh



#NAME=booksonic
NAME=${0}
IMAGE=linuxserver/${NAME}
CONFIGDIR=${DOCKER_DL}/${NAME}/config


dockerPull ${IMAGE} # fetch the latest image
dockerStopRm ${NAME} # kill the old one


# create the dir if needed
if [ ! -d ${CONFIGDIR} ]; then
  sudo -u \#${DOCKER_UID} mkdir -p ${CONFIGDIR}
fi


echo "Making a backup"
sudo -u \#${DOCKER_UID} tar -czf ${DOCKER_D1}/${NAME}.tgz -C ${DOCKER_DL} ${NAME}


# Direct access
# --cpu-shares=1024 # default job priority
sudo docker run --detach --restart=always \
  --name ${NAME} \
  --cpus=2 \
  --cpu-shares=1024 \
  --env PUID=${DOCKER_UID} \
  --env PGID=${DOCKER_GID} \
  --env TZ=${LOCAL_TZ} \
  --publish published=4040,target=4040,protocol=tcp,mode=ingress \
  --mount type=bind,src=${CONFIGDIR},dst=/config \
  --mount type=bind,src=${DATA1}/media/Audiobook,dst=/audiobooks \
  ${IMAGE}
  

# access via traefik
# https://github.com/DoTheEvo/Traefik-v2-examples
# https://stackoverflow.com/questions/59830648/traefik-multiple-port-bindings-for-the-same-host-v2
#dockerNetworkCreate ${NETWORK_INTERNET}
#sudo docker run --detach --restart=always \
#  --name ${NAME} \
#  --cpus=2 \
#  --cpu-shares=1024 \
#  --env PUID=${DOCKER_UID} \
#  --env PGID=${DOCKER_GID} \
#  --env TZ=${LOCAL_TZ} \
#  --env CALIBRE_OVERRIDE_DATABASE_PATH="/config/metadata.db" \
#  --mount type=bind,src=${CONFIGDIR},dst=/config \
#  --mount type=bind,src=${DATA1}/media,dst=/media \
#  --network=${NETWORK_INTERNET} \
#  --label traefik.enable=true \
#  --label traefik.http.routers.${NAME}_web.rule=Host\(\`${NAME}.${MY_DOMAIN}\`\) \
#  --label traefik.http.routers.${NAME}_web.entrypoints=http \
#  --label traefik.http.routers.${NAME}_web.service=${NAME}_web_svc \
#  --label traefik.http.services.${NAME}_web_svc.loadbalancer.server.port=4040 \
#  ${IMAGE}



