#!/bin/sh

# reload all the containers
HOSTNAME=`hostname -s`

if [ ${HOSTNAME} = "d01" ]; then
  echo ${HOSTNAME}
  ~/scripts/docker/swag.sh  # run this first

  #~/scripts/docker/ddclient.sh
  ~/scripts/docker/heimdall.sh

  #~/scripts/docker/unifi-controller.sh
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
  # d03 uses docker-compose instead of shell scripts
  if [ -f ~/scripts/d03/docker-compose.yml ]; then
    cd ~/scripts/d03 || exit 1
    docker compose pull
    docker compose up -d
  else
    echo "docker-compose.yml not found for d03"
  fi

elif [ ${HOSTNAME} = "ns01" ]; then
  echo ${HOSTNAME}
   ~/scripts/docker/pihole-ns01.sh

elif [ ${HOSTNAME} = "ns02" ]; then
  echo ${HOSTNAME}
   ~/scripts/docker/pihole-ns02.sh

fi


