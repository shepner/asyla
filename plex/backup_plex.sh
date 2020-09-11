#!/bin/sh

sudo service plexmediaserver stop

sudo sudo tar -v -czf /mnt/nas/data1/docker/plexmediaserver.tgz -C /var/lib/ plexmediaserver

# To restore:
#sudo tar -v -xzf /mnt/nas/data1/docker/plexmediaserver.tgz -C /var/lib/

sudo service plexmediaserver start
