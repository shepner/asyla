#!/bin/sh

# update all of the configs
~/update_scripts.sh


# reload all the containers
HOSTNAME=`hostname -s`

if [ ${HOSTNAME} = "d01" ]; then
  echo ${HOSTNAME}

  ~/scripts/docker/ddclient.sh
  ~/scripts/docker/unifi-controller.sh
  ~/scripts/docker/jupyter/jupyter.sh

  ~/scripts/docker/calibre.sh
  ~/scripts/docker/booksonic.sh
  
  ~/scripts/docker/downloads/transmission.sh
  ~/scripts/docker/downloads/jackett.sh
  ~/scripts/docker/downloads/sonarr.sh

  # run this last
  ~/scripts/docker/swag.sh
elif [ ${HOSTNAME} = "d02" ]; then
  echo ${HOSTNAME}
  ~/scripts/docker/foldingathome.sh

elif [ ${HOSTNAME} = "d03" ]; then
  echo ${HOSTNAME}

elif [ ${HOSTNAME} = "ns01" ]; then
  echo ${HOSTNAME}
  ~/scripts/docker/dnsmasq.sh

fi


