#!/bin/sh
# restore the docker config folders

# THIS NEEDS WORKED ON

cd /mnt/nas/data1/docker

for NAME in *.backup-`hostname`; do
  if [ -d "$NAME" ]; then
    echo $NAME
    #sudo -u docker rsync -v -a $NAME.backup-`hostname` /docker/$NAME
  fi
done
