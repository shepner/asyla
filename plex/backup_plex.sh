#!/bin/sh

sudo service plexmediaserver stop

# need to use `tar` because rsync throws errors
#sudo sudo tar -cvf /mnt/nas/docker1/plex.backup/plexmediaserver.tar -C /var/lib/ plexmediaserver
#sudo sudo tar -cvf /mnt/nas/docker1/plex.backup/plexmediaserver.tar -C /var/lib/ plexmediaserver
sudo sudo tar -cvf /mnt/nas/data1/docker/plex.backup/plexmediaserver.tar -C /var/lib/ plexmediaserver

# To restore:
#sudo tar -xvf /mnt/nas/data1/docker/plex.backup/plexmediaserver.tar -C /var/lib/

sudo service plexmediaserver start
