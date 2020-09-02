#!/bin/sh
# Portainer agent
# https://www.portainer.io
# https://www.portainer.io/installation/

# Portainer agent


# Load environment variables
. ~/scripts/docker/docker.env


NAME=portainer_agent
IMAGE=portainer/agent

# fetch the latest image
sudo docker pull $IMAGE

# stop the image if it is running
if [ `sudo docker ps -q -f name=$NAME` ]; then
  sudo docker stop $NAME
fi

# remove the stopped image if it exists
if [ `sudo docker ps -aq --filter "name=$NAME" --filter "status=exited"` ]; then
  sudo docker rm -v $NAME
fi


# create the network if needed
NETWORK=traefik_net
if [ ! `sudo docker network ls --quiet --filter "name=$NETWORK"` ]; then
  sudo docker network create $NETWORK
fi

# start the image
sudo docker run --detach --restart=always \
  --name $NAME \
  --cpus=1 \
  --cpu-shares=1024 \
  --network=traefik_net \
  --volume /var/run/docker.sock:/var/run/docker.sock \
  --volume /var/lib/docker/volumes:/var/lib/docker/volumes \
  $IMAGE

