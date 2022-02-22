#!/bin/sh
# Configure the system


# everything following will be as root
doas ash


# setup the repos
# https://wiki.alpinelinux.org/wiki/Enable_Community_Repository
apk update
cat > /etc/apk/repositories << EOF; $(echo)
https://dl-cdn.alpinelinux.org/alpine/v$(cat /etc/alpine-release | cut -d'.' -f1,2)/main/
https://dl-cdn.alpinelinux.org/alpine/v$(cat /etc/alpine-release | cut -d'.' -f1,2)/community/
# https://dl-cdn.alpinelinux.org/alpine/edge/testing/
EOF
apk update


# patch/update
apk update \
  && apk upgrade


# QEMU agent
# https://gitlab.alpinelinux.org/alpine/aports/-/issues/12204
apk update \
  && apk add qemu-guest-agent \
  && rc-update add qemu-guest-agent boot

