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

