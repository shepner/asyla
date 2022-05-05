#!/bin/sh
# https://docs.linuxserver.io/images/docker-ddclient


# Load the global functions and default environment variables
#. ~/scripts/docker/common.sh
NAME=`basename "${0}" ".sh"`
BASEDIR=$(dirname "$0")

doas docker compose -f ${BASEDIR}/${NAME}.yml up --detach
#docker stack deploy --compose-file ${BASEDIR}/${NAME}.yml ${NAME}
#docker stack deploy --compose-file name1.yaml --compose-file name2.yaml ${NAME}

#docker service ls
#docker stack rm ${NAME}




