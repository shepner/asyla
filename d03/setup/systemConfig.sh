#!/bin/sh
# Configure the system


# setup the repos
# https://wiki.alpinelinux.org/wiki/Enable_Community_Repository
doas apk update
echo "https://dl-cdn.alpinelinux.org/alpine/v$(cat /etc/alpine-release | cut -d'.' -f1,2)/main/" | doas tee --append /etc/apk/repositories
echo "https://dl-cdn.alpinelinux.org/alpine/v$(cat /etc/alpine-release | cut -d'.' -f1,2)/community/" | doas tee --append /etc/apk/repositories
doas apk update


# patch/update
doas apk update && apk upgrade


# QEMU agent
# https://gitlab.alpinelinux.org/alpine/aports/-/issues/12204
doas apk update \
  && doas apk add qemu-guest-agent \
  && doas rc-update add qemu-guest-agent boot

