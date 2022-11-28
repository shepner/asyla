#!/bin/sh

sudo service plexmediaserver stop

sudo sudo tar -v -cf /mnt/nas/data1/docker/plexmediaserver.tar -C /var/lib/ plexmediaserver

# To restore:
#sudo tar -v -xf /mnt/nas/data1/docker/plexmediaserver.tar -C /var/lib/

sudo service plexmediaserver start
