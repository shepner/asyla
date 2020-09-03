#!/bin/sh
# Portainer
# https://www.portainer.io
# https://www.portainer.io/installation/

# Portainer server


# Load functions and environment variables
. ~/scripts/docker/docker.env


NAME=portainer
IMAGE=portainer/portainer


# Update the image
dockerServiceUpdate $NAME


# create the network label
NETWORK=portainer_agent_network
dockerServiceNetworkCreate $NETWORK


# create the network label
#NETWORK=traefik_net
#dockerNetworkCreate $NETWORK

# start the image
sudo docker service create \
  --name $NAME \
  --replicas=1 \
  --cpus=2 \
  --cpu-shares=1024 \
  --network=$NETWORK \
  --publish 9000:9000 \
  --mount type=bind,src=/mnt/nas/docker/portainer,dst=/data \
  --label traefik.enable=true \
  --label traefik.http.routers.portainer.entrypoints=web \
  --label traefik.http.routers.portainer.rule=Host\(\`$NAME.$MY_DOMAIN\`\) \
  $IMAGE -H "tcp://tasks.portainer_agent:9001" --tlsskipverify

