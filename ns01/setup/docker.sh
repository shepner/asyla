#!/bin/sh
# Docker

# Create docker service account
sudo adduser --home /home/docker --uid 1003 --gid 1000 --shell /bin/bash docker

sudo gpasswd -a docker sudo

# setup a working dir

sudo mkdir -p /docker
sudo chown -R docker:asyla /docker
sudo chmod -R 774 /docker

# Install Docker Engine on Ubuntu:

# Update the apt package index and install packages to allow apt to use a repository over HTTPS:
sudo apt-get update

sudo apt-get install -y \
    apt-transport-https \
    ca-certificates \
    curl \
    gnupg-agent \
    software-properties-common

# Add Docker’s official GPG key:
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo apt-key add -

# Use the following command to set up the stable repository
sudo add-apt-repository \
   "deb [arch=amd64] https://download.docker.com/linux/ubuntu \
   $(lsb_release -cs) \
   stable"

# INSTALL DOCKER ENGINE
# Update the apt package index, and install the latest version of Docker Engine and containerd, or go to the next step to install a specific version:
sudo apt-get update
sudo apt-get install -y docker-ce docker-ce-cli containerd.io

# Install Docker Compose
sudo curl -L "https://github.com/docker/compose/releases/download/1.26.2/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
sudo chmod 755 /usr/local/bin/docker-compose

