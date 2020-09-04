#!/bin/sh

# update all of the configs
~/update_scripts.sh


# reload all the containers
HOSTNAME=`hostname -s`

if [ ${HOSTNAME} -eq "d01" ]; then
~/scripts/docker/traefik/traefik.sh

~/scripts/docker/calibre.sh
~/scripts/docker/booksonic.sh
elif [ ${HOSTNAME} -eq "d02" ]; then

elif [ ${HOSTNAME} -eq "d03" ]; then

fi


