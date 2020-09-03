#!/bin/sh
# Portainer
# https://www.portainer.io
# https://www.portainer.io/installation/

# Portainer server


# Load functions and environment variables
#. ~/scripts/docker/docker.env


cd /tmp
curl -L https://downloads.portainer.io/portainer-agent-stack.yml -o portainer-agent-stack.yml
sudo docker stack deploy --compose-file=portainer-agent-stack.yml portainer
sudo rm portainer-agent-stack.yml



#NAME=portainer
#IMAGE=portainer/portainer


# Update the image
#dockerServiceUpdate $NAME


# create the network label
#NETWORK=portainer_agent_network
#dockerServiceNetworkCreate $NETWORK

# create the data volume
#VOLUME=portainer_data
#dockerVolumeCreate portainer_data


# create the network label
#NETWORK=traefik_net
#dockerNetworkCreate $NETWORK

# start the image
#sudo docker service create \
#  --name $NAME \
#  --replicas=1 \
#  --network=$NETWORK \
#  --publish 9000:9000 \
#  --mount type=bind,src=$VOLUME,dst=/data \
#  --label traefik.enable=true \
#  --label traefik.http.routers.portainer.entrypoints=web \
#  --label traefik.http.routers.portainer.rule=Host\(\`$NAME.$MY_DOMAIN\`\) \
#  $IMAGE -H "tcp://tasks.portainer_agent:9001" --tlsskipverify

