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
dockerContainerUpdate $IMAGE
# Shut down the old image
dockerContainerKill $NAME


# create a volume to store the data
VOLUME=portainer_data
dockerVolumeCreate $VOLUME

# create the network label
NETWORK=traefik_net
dockerNetworkCreate $NETWORK

# start the image
sudo docker run --detach --restart=always \
  --name $NAME \
  --cpus=2 \
  --cpu-shares=1024 \
  --network=$NETWORK \
  --volume /var/run/docker.sock:/var/run/docker.sock \
  --volume $VOLUME:/data \
  --label traefik.enable=true \
  --label traefik.http.routers.portainer.entrypoints=web \
  --label traefik.http.routers.portainer.rule=Host\(\`$NAME.$MY_DOMAIN\`\) \
  $IMAGE

