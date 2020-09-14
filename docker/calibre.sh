#!/bin/sh
# https://docs.linuxserver.io/images/docker-calibre

# 8080: Calibre desktop gui. ctrl-alt-shift to access the clipboard
# 8081: Calibre webserver
# 3389: RDP of Calibre desktop

# [Customizing calibre](https://manual.calibre-ebook.com/customize.html)
# Environment variables:
# * CALIBRE_OVERRIDE_DATABASE_PATH - allows you to specify the full path to metadata.db. Using this variable you can have metadata.db be in a location other than the library folder. Useful if your library folder is on a networked drive that does not support file locking.


# Load the functions and environment variables
. ~/scripts/docker/common.sh


NAME=calibre
IMAGE=linuxserver/calibre
DOCKERDIR=${DOCKER_DL}
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


# direct access
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
#  --publish published=6080,target=8080,protocol=tcp,mode=ingress \
#  --publish published=6081,target=8081,protocol=tcp,mode=ingress \
#  ${IMAGE}

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
#  --label traefik.http.routers.${NAME}_desktop.rule=Host\(\`${NAME}.${MY_DOMAIN}\`\) \
#  --label traefik.http.routers.${NAME}_desktop.entrypoints=http \
#  --label traefik.http.routers.${NAME}_desktop.service=${NAME}_desktop_svc \
#  --label traefik.http.services.${NAME}_desktop_svc.loadbalancer.server.port=8080 \
#  --label traefik.http.routers.${NAME}_webserver.rule=Host\(\`${NAME}.${MY_DOMAIN}\`\) \
#  --label traefik.http.routers.${NAME}_webserver.entrypoints=calibre_web_ep \
#  --label traefik.http.routers.${NAME}_webserver.service=${NAME}_webserver_svc \
#  --label traefik.http.services.${NAME}_webserver_svc.loadbalancer.server.port=8081 \
#  ${IMAGE}

# access via traefik
# https://github.com/DoTheEvo/Traefik-v2-examples
# https://stackoverflow.com/questions/59830648/traefik-multiple-port-bindings-for-the-same-host-v2
dockerNetworkCreate_general
sudo -u \#${DOCKER_UID} cp ~/scripts/docker/calibre.yaml ${DOCKER_D2}/traefik/config
~/scripts/docker/traefik/traefik.sh
sudo docker run --detach --restart=always \
  --name ${NAME} \
  --cpus=2 \
  --cpu-shares=1024 \
  --env PUID=${DOCKER_UID} \
  --env PGID=${DOCKER_GID} \
  --env TZ=${LOCAL_TZ} \
  --env CALIBRE_OVERRIDE_DATABASE_PATH="/config/metadata.db" \
  --mount type=bind,src=${CONFIGDIR},dst=/config \
  --mount type=bind,src=${DATA1}/media,dst=/media \
  --network=general \
  ${IMAGE}


