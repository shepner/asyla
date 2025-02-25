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

doas cp ${DOCKER_D2}/pihole/03-lan-dns.conf ${DOCKERAPPDIR}/etc-dnsmasq.d/

doas docker run --detach --restart=unless-stopped \
  --name ${NAME} \
  --dns=1.1.1.1 \
  --dns=1.0.0.1 \
  --dns=2606:4700:4700::1111 \
  --dns=2606:4700:4700::1001 \
  --env TZ=${LOCAL_TZ} \
  --env FTLCONF_webserver_api_password='' `# set a password here or remove for random one` \
  --env FTLCONF_dns_listeningMode='all' \
  --env PIHOLE_UID=${DOCKER_UID} \
  --env PIHOLE_GID=${DOCKER_GID} \
  --env FTLCONF_dns_dnssec='true' \
  --env FTLCONF_dns_domain=${NAME}.${MY_DOMAIN} \
  --env FTLCONF_misc_etc_dnsmasq_d=true `# Load custom user configuration files from /etc/dnsmasq.d/` \
  --mount type=bind,src=${DOCKERAPPDIR}/etc-pihole,dst=/etc/pihole \
  --mount type=bind,src=${DOCKERAPPDIR}/etc-dnsmasq.d,dst=/etc/dnsmasq.d \
  --mount type=bind,src=${DOCKER_D2}/pihole/hosts,dst=/etc/hosts \
  --cap-add=NET_ADMIN `# Required if you are using Pi-hole as your DHCP server, else not needed` \
  --cap-add=SYS_NICE `# Optional, if Pi-hole should get some more processing time` \
  --net=host `# For DHCP it is recommended to remove these ports and instead add: network_mode: "host"` \
`:  --publish published=53,target=53,protocol=tcp,mode=ingress` \
`:  --publish published=53,target=53,protocol=udp,mode=ingress` \
`:  --publish published=67,target=67,protocol=udp,mode=ingress` \
`:  --publish published=80,target=80,protocol=tcp,mode=ingress` \
`:  --publish published=443,target=443,protocol=tcp,mode=ingress` \
  ${IMAGE}

#dockerRestartProxy

# enter shell to troubleshoot:
#doas docker exec -it pihole-ns02 /bin/bash

