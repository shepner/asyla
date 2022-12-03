#!/bin/sh

# update all of the configs
~/update_scripts.sh


# reload all the containers
HOSTNAME=`hostname -s`

if [ ${HOSTNAME} = "d01" ]; then
  echo ${HOSTNAME}
  ~/scripts/docker/swag.sh  # run this first

  #~/scripts/docker/ddclient.sh
  ~/scripts/docker/heimdall.sh

  ~/scripts/docker/unifi-controller.sh
  ~/scripts/docker/homebridge.sh
  ~/scripts/docker/duplicati.sh

  ~/scripts/docker/jupyter/jupyter.sh

  ~/scripts/docker/calibre.sh
  ~/scripts/docker/booksonic.sh
  
  ~/scripts/docker/transmission.sh
  ~/scripts/docker/flaresolverr.sh
  ~/scripts/docker/jackett.sh
  ~/scripts/docker/sonarr.sh

  ~/scripts/docker/swag.sh  # run this last
elif [ ${HOSTNAME} = "d02" ]; then
  echo ${HOSTNAME}
  # ~/scripts/docker/foldingathome.sh
  ~/scripts/docker/plex.sh

elif [ ${HOSTNAME} = "d03" ]; then
  echo ${HOSTNAME}

fi


