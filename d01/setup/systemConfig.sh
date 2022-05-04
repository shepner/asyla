#!/bin/sh
# Configure the system


# setup the repos
# https://wiki.alpinelinux.org/wiki/Enable_Community_Repository
doas apk update
echo "https://dl-cdn.alpinelinux.org/alpine/v$(cat /etc/alpine-release | cut -d'.' -f1,2)/main/" | doas tee -a /etc/apk/repositories
echo "https://dl-cdn.alpinelinux.org/alpine/v$(cat /etc/alpine-release | cut -d'.' -f1,2)/community/" | doas tee -a /etc/apk/repositories
doas apk update


# patch/update
doas apk update && doas apk upgrade


# QEMU agent
# https://gitlab.alpinelinux.org/alpine/aports/-/issues/12204
doas apk update \
  && doas apk add qemu-guest-agent \
  && doas rc-update add qemu-guest-agent boot


# Forward log messages
# https://wiki.alpinelinux.org/wiki/Syslog
echo 'SYSLOGD_OPTS="-t -L -R 10.0.0.73:514"' | doas tee /etc/conf.d/syslog
doas rc-service syslog restart


