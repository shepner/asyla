#!/bin/sh
# https://github.com/pi-hole/docker-pi-hole/#running-pi-hole-docker


# Load the global functions and default environment variables
. ~/scripts/docker/common.sh


# Setup the app specific environment vars
IMAGE=pihole/${NAME}
#DOCKERDIR=${DOCKER_DL} # local disk
DOCKERDIR=${DOCKER_D1} # NFS attached HDD
#DOCKERDIR=${DOCKER_D2} # NFS attached SSD
DOCKERAPPDIR=${DOCKERDIR}/${NAME}
CONFIGDIR=${DOCKERAPPDIR}/config

IP=`hostname -I | awk '{print $1}'`


# Perform setups/updates as needed
dockerPull ${IMAGE} # fetch the latest image
dockerStopRm ${NAME} # kill the old one
dockerNetworkCreate ${NETWORK} # create the network if needed
#appCreateDir ${CONFIGDIR} # create the config folder if needed
appCreateDir ${DOCKERAPPDIR}/etc-pihole
appCreateDir ${DOCKERAPPDIR}/etc-dnsmasq.d
#appBackup ${DOCKERDIR} ${NAME} # backup the app


sudo docker run --detach --restart=unless-stopped \
  --name ${NAME} \
  --env TZ=${LOCAL_TZ} \
  --network=${NETWORK} \
  --publish published=5353,target=53,protocol=tcp,mode=ingress \
  --publish published=5353,target=53,protocol=udp,mode=ingress \
  --publish published=9080,target=80,protocol=udp,mode=ingress \
  --mount type=bind,src=${DOCKERAPPDIR}/etc-pihole,dst=/etc/pihole \
  --mount type=bind,src=${DOCKERAPPDIR}/etc-dnsmasq.d,dst=/etc/dnsmasq.d \
  --dns=208.67.222.222 \
  --dns=208.67.220.220 \
  --hostname pi.hole \
  --env VIRTUAL_HOST="pi.hole" \
  --env PROXY_LOCATION="pi.hole" \
  --env ServerIP=${IP} `: Needs to be the external IP `\
  ${IMAGE}:latest

dockerRestartProxy


#printf 'Starting up pihole container '
#for i in $(seq 1 20); do
#    if [ "$(docker inspect -f "{{.State.Health.Status}}" ${NAME})" == "healthy" ] ; then
#        printf ' OK'
#        echo -e "\n$(docker logs ${NAME} 2> /dev/null | grep 'password:') for your pi-hole: https://${IP}/admin/"
#        exit 0
#    else
#        sleep 3
#        printf '.'
#    fi

#    if [ $i -eq 20 ] ; then
#        echo -e "\nTimed out waiting for Pi-hole start, consult your container logs for more info (\`docker logs pihole\`)"
#        exit 1
#    fi
#done;
