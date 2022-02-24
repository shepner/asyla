#!/bin/sh
# Docker


# Install Docker

doas apk update \
  && doas apk policy docker \
  && doas apk add \
    docker \
    docker-compose \
  && doas addgroup root docker \
  && doas rc-update add docker boot \
  && doas service docker start


# Install Docker Compose v2
# https://docs.docker.com/compose/cli-command/

doas mkdir -p /root/.docker/cli-plugins/
doas curl -SL https://github.com/docker/compose/releases/download/v2.2.3/docker-compose-linux-x86_64 -o /root/.docker/cli-plugins/docker-compose
doas chmod +x /root/.docker/cli-plugins/docker-compose

# Show the version
doas docker compose version


# Uninstall v2
# doas rm /root/.docker/cli-plugins/docker-compose

