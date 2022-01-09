#!/bin/sh


# Patch the system
apk update && apk upgrade


# Install sshd
# https://wiki.alpinelinux.org/wiki/Setting_up_a_SSH_server
apk add openssh
rc-update add sshd
/etc/init.d/sshd start














