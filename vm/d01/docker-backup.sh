#!/bin/sh
# backup the docker config folders

cd /docker

for NAME in *; do
  if [ -d "$NAME" ]; then
    echo $NAME
    sudo docker stop $NAME
    sleep 10
    sudo -u docker rsync -v -a $NAME /mnt/nas/data1/docker/$NAME.backup-`hostname`
    sudo docker start $NAME
  fi
done
