#!/bin/sh
# https://github.com/pi-hole/docker-pi-hole/#running-pi-hole-docker
# https://github.com/pi-hole/docker-pi-hole/#tips-and-tricks
# sudo docker exec -it pihole /bin/bash

# Load the global functions and default environment variables
. ~/scripts/swarm/common.sh


# Setup the app specific environment vars
IMAGE=pihole/${NAME}
#DOCKERDIR=${DOCKER_DL} # local disk
DOCKERDIR=${DOCKER_D1} # NFS attached HDD
#DOCKERDIR=${DOCKER_D2} # NFS attached SSD
DOCKERAPPDIR=${DOCKERDIR}/${NAME}
CONFIGDIR=${DOCKERAPPDIR}/config

IP=`ip addr show eth0 | grep -oE '((1?[0-9][0-9]?|2[0-4][0-9]|25[0-5])\.){3}(1?[0-9][0-9]?|2[0-4][0-9]|25[0-5])'`



# Perform setups/updates as needed
dockerPull ${IMAGE} # fetch the latest image
dockerServiceRm ${NAME} # kill the old one
dockerNetworkCreate ${NETWORK} # create the network if needed


#https://codeopolis.com/posts/mounting-nfs-shares-as-docker-volumes/
#doas docker volume ls -q --filter "name=pihole_vol"
doas docker volume create --name=${VOLUME} --driver local \
  --opt type=nfs3 \
  --opt o=addr=nas.asyla.org,rw,noatime,rsize=8192,wsize=8192,tcp,timeo=14 \
  --opt device=:${DOCKERDIR}/${NAME}


##appCreateDir ${CONFIGDIR} # create the config folder if needed
#appCreateDir ${DOCKERAPPDIR}/etc-pihole
#appCreateDir ${DOCKERAPPDIR}/etc-dnsmasq.d
##appBackup ${DOCKERDIR} ${NAME} # backup the app


doas docker service create --replicas 1 \
  --name ${NAME} \
  --env TZ=${LOCAL_TZ} \
  --network=${NETWORK} \
  --publish published=5353,target=53,protocol=tcp,mode=ingress \
  --publish published=5353,target=53,protocol=udp,mode=ingress \
  --publish published=9080,target=80,protocol=tcp,mode=ingress \
  --mount type=volume,src=${VOLUME}/hosts,dst=/etc/hosts,volume-driver=local\
  --env ServerIP=${IP} `: Needs to be the external IP `\
  --env PIHOLE_DOMAIN="asyla.org" \
  --hostname "pihole.asyla.org" \
  --env VIRTUAL_HOST=`hostname` \
  `: --dns=127.0.0.1 `\
  `: --dns=208.67.222.222 `\
  `: --dns=208.67.220.220 `\
  `: --env PROXY_LOCATION="pi.hole" `\
  ${IMAGE}:latest

#dockerRestartProxy


#  --mount type=bind,src=${DOCKERAPPDIR}/hosts,dst=/etc/hosts \
#  --mount type=bind,src=${DOCKERAPPDIR}/etc-pihole,dst=/etc/pihole \
#  --mount type=bind,src=${DOCKERAPPDIR}/etc-dnsmasq.d,dst=/etc/dnsmasq.d \

