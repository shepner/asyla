. ~/scripts/docker/common.env

dockerPull () {
  # fetch the latest image
  sudo docker pull $1
}

dockerStopRm () {
  # stop and remove the image if it is running
  if [ `sudo docker ps -q --filter "name=$1"` ]; then
    echo "Stopping container"
    sudo docker stop $1
    echo "Removing container"
    sudo docker rm -v $1
  fi

  # remove the image if it exists in some other state
  if [ `sudo docker ps -aq --filter "name=$1"` ]; then
    echo "Removing container"
    sudo docker rm -v $1
  fi
}

dockerVolumeCreate () {
  # create the volume if needed
  if [ ! `sudo docker volume ls --quiet --filter "name=$1"` ]; then
    echo "Creating volume"
    sudo docker volume create $1
  fi
}

dockerNetworkCreate () {
  # create the network if needed
  if [ ! `sudo docker network ls --quiet --filter "name=$1"` ]; then
    echo "Creating network"
    sudo docker network create $1
  fi
}

dockerServiceUpdate () {
  # update the service to the latest image
  if [ `sudo docker service ls --quiet --filter "name=$1"` ]; then
    sudo docker service update --force $1
  fi
}

dockerNetworkCreate () {
  # [docker network create](https://docs.docker.com/engine/reference/commandline/network_create/)
  if [ ! `sudo docker network ls --quiet --filter "name=$1"` ]; then
    sudo docker network create --driver overlay --attachable $1
  fi
}

dockerNetworkCreate_general () {
  # [docker network create](https://docs.docker.com/engine/reference/commandline/network_create/)
  dockerNetworkCreate_general_NAME=general
  if [ ! `sudo docker network ls --quiet --filter "name=${dockerNetworkCreate_general_NAME}"` ]; then
    sudo docker network create \
      --driver overlay \
      --attachable \
      --subnet=10.10.10.0/24 \
      --gateway=10.10.10.1 \
      ${dockerNetworkCreate_general_NAME}
  fi
}

appCreateDir () {
  # create the spedified directory if needed
  if [ ! -d ${1} ]; then
    sudo -u \#${DOCKER_UID} mkdir -p ${1}
  fi
}

appBackup () {
  # Backup the specified Docker app config folder to a common location
  echo "Making a backup"
  sudo -u \#${DOCKER_UID} tar -czf ${DOCKER_D1}/${2}.tgz -C ${1} ${2}
  echo "Backup complete"
}

