#!/bin/sh
# Portainer agent
# https://www.portainer.io
# https://www.portainer.io/installation/

# Portainer agent


# Load functions and environment variables
. ~/scripts/docker/docker.env


NAME=portainer_agent
IMAGE=portainer/agent


# Update the image
dockerServiceUpdate $NAME


# create the network label
NETWORK=portainer_agent_network
dockerServiceNetworkCreate $NETWORK


# start the image
sudo docker service create \
  --name $NAME \
  --cpus=1 \
  --cpu-shares=1024 \
  --mode global \
  --constraint 'node.platform.os == linux' \
  --env AGENT_CLUSTER_ADDR=tasks.portainer_agent \
  --network $NETWORK \
  --mount type=bind,src=/var/run/docker.sock,dst=/var/run/docker.sock \
  --mount type=bind,src=/var/lib/docker/volumes,dst=/var/lib/docker/volumes \
  $IMAGE

