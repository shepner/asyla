. ~/scripts/docker/common.env

dockerPull () {
  # fetch the latest image
  doas docker pull $1
}

dockerStopRm () {
  # stop and remove the image if it is running
  if [ `doas docker ps -q --filter "name=$1"` ]; then
    echo "Stopping container"
    doas docker stop $1
    echo "Removing container"
    doas docker rm -v $1
  fi

  # remove the image if it exists in some other state
  if [ `doas docker ps -aq --filter "name=$1"` ]; then
    echo "Removing container"
    doas docker rm -v $1
  fi
}

dockerVolumeCreate () {
  # create the volume if needed
  if [ ! `doas docker volume ls --quiet --filter "name=$1"` ]; then
    echo "Creating volume"
    doas docker volume create $1
  fi
}

dockerNetworkCreate () {
  # create the network if needed
  if [ ! `doas docker network ls --quiet --filter "name=$1"` ]; then
    echo "Creating network"
    doas docker network create $1
  fi
}

dockerServiceUpdate () {
  # update the service to the latest image
  if [ `doas docker service ls --quiet --filter "name=$1"` ]; then
    doas docker service update --force $1
  fi
}

dockerNetworkCreate () {
  # [docker network create](https://docs.docker.com/engine/reference/commandline/network_create/)
  if [ ! `doas docker network ls --quiet --filter "name=$1"` ]; then
    # use overlay with swarm
    #doas docker network create --driver overlay --attachable $1
    doas docker network create --driver bridge --attachable $1
  fi
}

dockerNetworkCreate_general () {
  # [docker network create](https://docs.docker.com/engine/reference/commandline/network_create/)
  dockerNetworkCreate_general_NAME=general
  if [ ! `doas docker network ls --quiet --filter "name=${dockerNetworkCreate_general_NAME}"` ]; then
    doas docker network create \
      --driver overlay \
      --attachable \
      --subnet=10.10.10.0/24 \
      --gateway=10.10.10.1 \
      ${dockerNetworkCreate_general_NAME}
  fi
}

dockerRestartProxy () {
  # this is to quick-restart the proxy service without running its script
  PROXY_NAME=swag
  if [ `doas docker ps -q --filter "name=${PROXY_NAME}"` ]; then
    echo "Restarting ${PROXY_NAME}"
    doas docker stop ${PROXY_NAME}
    doas docker start ${PROXY_NAME}
  else
    echo "WARNING: ${PROXY_NAME} was not running!"
  fi
}

appCreateDir () {
  # create the spedified directory if needed
  if [ ! -d ${1} ]; then
    doas mkdir -p ${1}
    doas chown -R docker:asyla ${1}
  fi
}

appBackup () {
  # Backup the specified Docker app config folder to a common location
  echo "Making a backup"
  doas tar -czf ${DOCKER_D1}/${2}.tgz -C ${1} ${2}
  echo "Backup complete"
}

