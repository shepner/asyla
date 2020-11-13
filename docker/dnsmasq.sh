#!/bin/sh
# https://github.com/shepner/Docker-DNSmasq

# Combined DNS and DHCP server

# WARNING: This runs with privledged rights

NAME=`basename "${0}" ".sh"`
IMAGE=shepner/${NAME}
BASEPATH=${DOCKER_D2}/${NAME}
CONFIGDIR=${BASEPATH}/config


dockerPull ${IMAGE} # fetch the latest image
dockerStopRm ${NAME} # kill the old one


# create the dir if needed
if [ ! -d ${BASEPATH} ]; then
  sudo -u \#${DOCKER_UID} mkdir -p ${BASEPATH}
  #sudo wget -O $BASEPATH/config/dnsmasq_dhcp.conf https://raw.githubusercontent.com/shepner/Docker-DNSmasq/master/dnsmasq.conf
  #sudo wget -O $BASEPATH/config/dnsmasq.conf https://raw.githubusercontent.com/shepner/Docker-DNSmasq/master/dnsmasq.conf
  #sudo wget -O $BASEPATH/resolv.conf https://raw.githubusercontent.com/shepner/Docker-DNSmasq/master/resolv.conf
fi


echo "Making a backup"
sudo -u \#${DOCKER_UID} tar -czf ${DOCKER_D1}/${NAME}.tgz -C ${DOCKER_DL} ${NAME}



sudo docker run --detach --restart=always \
  --name=${NAME} \
  --cpus=2 \
  --cpu-shares=2048 \
  --privileged \
  --mount type=bind,src=${BASEPATH},dst=/mnt \
  --env DNSMASQ_CONF=/mnt/config/dnsmasq_combined.conf \
  --network host \
  ${IMAGE}
