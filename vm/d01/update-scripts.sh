#!/bin/sh

REPO=shepner/proxmox-docker

if [ -d ~/scripts ]; then
  sudo rm -R ~/scripts
fi

git clone https://github.com/$REPO.git ~/scripts

find ~/scripts -name "*.sh" -exec chmod 744 {} \;

mv ~/scripts/*.sh ~
