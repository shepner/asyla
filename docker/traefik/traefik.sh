#!/bin/sh
# [Traefik v2](https://github.com/DoTheEvo/Traefik-v2-examples#1-traefik-routing-to-various-docker-containers) examples


# Load the functions and environment variables
. ~/scripts/docker/common.sh


NAME=traefik
DOCKERDIR=${DOCKER_D2}
DOCKERAPPDIR=${DOCKERDIR}/${NAME}
CONFIGDIR=${DOCKERAPPDIR}/config


# create the dir if needed
if [ ! -d ${CONFIGDIR} ]; then
  sudo -u \#${DOCKER_UID} mkdir -p ${CONFIGDIR}
  sudo chmod -R 775 ${DOCKERAPPDIR}
fi

# Copy the Traefik support files
sudo -u \#${DOCKER_UID} cp ~/scripts/docker/${NAME}/${NAME}.yaml ${DOCKERAPPDIR}
sudo -u \#${DOCKER_UID} cp ~/scripts/docker/${NAME}/usersFile.txt ${DOCKERAPPDIR}
sudo chmod 400 ${DOCKERAPPDIR}/usersFile.txt

# File to store the LetsEncrypt certificate and etc
sudo -u \#${DOCKER_UID} touch ${DOCKERAPPDIR}/acme.json
sudo -u \#${DOCKER_UID} chmod 600 ${DOCKERAPPDIR}/acme.json

#make sure ownership and permissions are correct
sudo chown -R ${DOCKER_UID}:${DOCKER_GID} ${DOCKERAPPDIR}
sudo chmod -R 664 ${CONFIGDIR}

dockerNetworkCreate_general

sudo docker-compose -f ~/scripts/docker/traefik/docker-compose.yaml --env-file ~/scripts/docker/common.env pull $NAME
sudo docker-compose -f ~/scripts/docker/traefik/docker-compose.yaml --env-file ~/scripts/docker/common.env rm --force --stop $NAME
sudo docker-compose -f ~/scripts/docker/traefik/docker-compose.yaml --env-file ~/scripts/docker/common.env up -d $NAME




