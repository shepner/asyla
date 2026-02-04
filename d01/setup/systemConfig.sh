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


# Ensure docker user's .ssh directory exists and has correct permissions
doas mkdir -p /home/docker/.ssh
doas chmod 700 /home/docker/.ssh
doas chown -R docker:asyla /home/docker/.ssh

# Ensure authorized_keys has correct permissions if it exists
if [ -f /home/docker/.ssh/authorized_keys ]; then
    doas chmod 600 /home/docker/.ssh/authorized_keys
    doas chown docker:asyla /home/docker/.ssh/authorized_keys
fi

# Add rsync to doas.conf for docker user (needed for migration script)
# https://wiki.alpinelinux.org/wiki/Doas
if ! grep -q "permit nopass docker as root cmd /usr/bin/rsync" /etc/doas.conf 2>/dev/null; then
    echo "permit nopass docker as root cmd /usr/bin/rsync" | doas tee -a /etc/doas.conf
fi


