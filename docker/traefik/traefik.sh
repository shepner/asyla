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
  sudo chmod 775 ${DOCKERAPPDIR}
fi

# Copy the Traefik support files
sudo -u \#${DOCKER_UID} cp ~/scripts/docker/${NAME}/${NAME}.yaml ${DOCKERAPPDIR}
sudo -u \#${DOCKER_UID} cp ~/scripts/docker/${NAME}/usersFile.txt ${DOCKERAPPDIR}
sudo chmod 400 ${DOCKERAPPDIR}/usersFile.txt
#make sure ownership is correct
sudo chown -R ${DOCKER_UID}:${DOCKER_GID} ${DOCKERAPPDIR}

dockerNetworkCreate_general


sudo docker-compose -f ~/scripts/docker/traefik/docker-compose.yaml --env-file ~/scripts/docker/common.env pull $NAME
sudo docker-compose -f ~/scripts/docker/traefik/docker-compose.yaml --env-file ~/scripts/docker/common.env rm --force --stop $NAME
sudo docker-compose -f ~/scripts/docker/traefik/docker-compose.yaml --env-file ~/scripts/docker/common.env up -d $NAME




