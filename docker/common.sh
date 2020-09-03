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
  if [ ! `sudo docker network ls --quiet --filter "name=$1"` ]; then
    sudo docker network create --driver overlay --attachable $1
  fi
}
