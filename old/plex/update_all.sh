#!/bin/sh

~/update_scripts.sh

sudo service plexmediaserver stop

~/update.sh
~/update_plex.sh

