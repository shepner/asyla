#!/bin/sh
# https://docs.linuxserver.io/images/docker-ddclient


# Load the global functions and default environment variables
#. ~/scripts/docker/common.sh
NAME=`basename "${0}" ".sh"`
BASEDIR=$(dirname "$0")



# https://docs.docker.com/engine/swarm/stack-deploy/


# run the `docker service` and `docker stack` commands on the swarm master node
#doas docker node ls


# Start the registry as a service on your swarm
#doas docker service create --name registry --publish published=5000,target=5000 registry:2
#doas docker service ls


# run in docker
doas docker compose -f ${BASEDIR}/${NAME}.yml up --detach
#doas docker compose -f ./scripts/swarm/ddclient.yml ps
#doas docker compose -f ./scripts/swarm/ddclient.yml down --volumes
#doas docker compose -f ./scripts/swarm/ddclient.yml push



# run on swarm 
#docker stack deploy --compose-file name1.yaml --compose-file name2.yaml ${NAME}
#doas docker stack deploy --compose-file ${BASEDIR}/${NAME}.yml ${NAME}
#doas docker service ls
#doas docker service scale ddclient_ddclient=0
#doas docker service rm ${NAME}




