#!/bin/sh
# https://docs.pi-hole.net/
# https://github.com/pi-hole/docker-pi-hole


# Load the global functions and environment variables
. ~/scripts/docker/common.sh


# Setup the app specific environment vars
IMAGE=pihole/pihole:latest
DOCKERDIR=${DOCKER_DL} # local disk
#DOCKERDIR=${DOCKER_D1} # NFS attached HDD
#DOCKERDIR=${DOCKER_D2} # NFS attached SSD
DOCKERAPPDIR=${DOCKERDIR}/${NAME}
#CONFIGDIR=${DOCKERAPPDIR}/config


# Perform setups/updates as needed
dockerPull ${IMAGE} # fetch the latest image
dockerStopRm ${NAME} # kill the old one
#dockerNetworkCreate ${NETWORK} # create the network if needed
appCreateDir ${DOCKERAPPDIR}/etc-pihole # create the folder if needed
appCreateDir ${DOCKERAPPDIR}/etc-dnsmasq.d # create the folder if needed
#appCreateDir ${CONFIGDIR} # create the folder if needed
appBackup ${DOCKERDIR} ${NAME} # backup the app


doas docker run --detach --restart=unless-stopped \
  --name ${NAME} \
`:  --hostname ns02.asyla.org` \
  --dns=1.1.1.1 \
  --env TZ=${LOCAL_TZ} \
  --env CMD_DOMAIN=${NAME}.${MY_DOMAIN} \
  --env CMD_PROTOCOL_USESSL=true \
  --env WEBPASSWORD='' `# set a password or it will be random` \
`:  --env VIRTUAL_HOST="pi.hole"` \
`:  --env PROXY_LOCATION="pi.hole"` \
`:  --env FTLCONF_LOCAL_IPV4="127.0.0.1"` \
  --mount type=bind,src=${DOCKERAPPDIR}/etc-pihole,dst=/etc/pihole \
  --mount type=bind,src=${DOCKERAPPDIR}/etc-dnsmasq.d,dst=/etc/dnsmasq.d \
  --mount type=bind,src=${DOCKER_D2}/pihole/hosts,dst=/etc/hosts \
  --cap-add=NET_ADMIN `# Required if you are using Pi-hole as your DHCP server, else not needed` \
  --net=host `# For DHCP it is recommended to remove these ports and instead add: network_mode: "host"` \
`:  --publish published=53,target=53,protocol=tcp,mode=ingress` \
`:  --publish published=53,target=53,protocol=udp,mode=ingress` \
`:  --publish published=67,target=67,protocol=udp,mode=ingress` \
`:  --publish published=80,target=80,protocol=tcp,mode=ingress` \
  ${IMAGE}

#dockerRestartProxy

