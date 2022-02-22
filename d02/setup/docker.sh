#!/bin/sh
# Docker


# everything following will be as root
#doas ash


# Install Docker

doas apk update \
  && apk policy docker \
  && apk add docker \
  && apk add docker-compose \
  && addgroup root docker \
  && rc-update add docker boot \
  && service docker start

