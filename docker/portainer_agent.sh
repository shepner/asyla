#!/bin/sh
# Portainer agent
# https://www.portainer.io
# https://www.portainer.io/installation/

# Portainer agent


# Load environment variables
. ~/scripts/docker/docker.env


NAME=portainer_agent
IMAGE=portainer/agent

# Update the image
dockerContainerUpdate $IMAGE
# Shut down the old image
dockerContainerKill $NAME


# create the network label
NETWORK=traefik_net
dockerNetworkCreate $NETWORK

# start the image
sudo docker run --detach --restart=always \
  --name $NAME \
  --cpus=1 \
  --cpu-shares=1024 \
  --network=$NETWORK \
  --volume /var/run/docker.sock:/var/run/docker.sock \
  --volume /var/lib/docker/volumes:/var/lib/docker/volumes \
  $IMAGE

