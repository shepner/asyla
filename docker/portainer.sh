#!/bin/sh
# Portainer
# https://www.portainer.io
# https://www.portainer.io/installation/

# Portainer server


# Load environment variables
. ~/scripts/docker/docker.env


NAME=portainer
IMAGE=portainer/portainer

echo $CONFIGDIR

sleep 60

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

# create a volume to store the data
sudo docker volume create portainer_data

# start the image
sudo docker run --detach --restart=always \
  --name $NAME \
  --cpus=2 \
  --cpu-shares=1024 \
  --network=traefik_net \
  --volume /var/run/docker.sock:/var/run/docker.sock \
  --volume portainer_data:/data \
  --label traefik.enable=true \
  --label traefik.http.routers.portainer.entrypoints=web \
  --label traefik.http.routers.portainer.rule=Host\(\`portainer.asyla.org\`\) \
  $IMAGE

