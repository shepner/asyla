#!/bin/sh
# https://docs.linuxserver.io/images/docker-ddclient


# Load the global functions and default environment variables
#. ~/scripts/docker/common.sh
NAME=`basename "${0}" ".sh"`
BASEDIR=$(dirname "$0")


# docker
#
doas docker compose -f ${BASEDIR}/${NAME}.yml up --detach
#
#doas docker compose -f ./scripts/compose/torrent.yml ps
#doas docker compose -f ./scripts/compose/torrent.yml down --volumes
#doas docker compose -f ./scripts/compose/torrent.yml push


# swarm
# https://docs.docker.com/engine/swarm/stack-deploy/
#
# run the `docker service` and `docker stack` commands on the swarm master node
#doas docker node ls
#
#doas docker stack deploy --compose-file name1.yaml --compose-file name2.yaml ${NAME}
#doas docker stack deploy --compose-file ${BASEDIR}/${NAME}.yml ${NAME}
#
#doas docker service ls
#doas docker service scale ddclient_ddclient=0
#doas docker service rm ${NAME}
#
#
#doas docker service scale torrent_sonarr=0
#doas docker service rm torrent_sonarr
#
#doas docker service scale torrent_jackett=0
#doas docker service rm torrent_jackett
#
#doas docker service scale torrent_transmission=0
#doas docker service rm torrent_transmission
#
#
# to access the shell, find the node and run:
#doas docker exec -it ${ID} bash

