#!/bin/sh
# Portainer
# https://www.portainer.io
# https://www.portainer.io/installation/

# Portainer server

sudo docker volume create portainer_data

NAME=portainer
IMAGE=portainer/portainer

sudo docker pull $IMAGE
sudo docker stop $NAME
sudo docker rm -v $NAME

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

#sudo docker run --detach --restart=always \
#  --name $NAME \
#  --cpus=2 \
#  --cpu-shares=1024 \
#  --publish published=8000,target=8000,protocol=tcp,mode=ingress \
#  --publish published=9000,target=9000,protocol=tcp,mode=ingress \
#  --volume /var/run/docker.sock:/var/run/docker.sock \
#  --volume portainer_data:/data \
#  $IMAGE
