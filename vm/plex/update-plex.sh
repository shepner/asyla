#!/bin/sh

sudo service plexmediaserver stop

sudo apt-get upgrade plexmediaserver

# https://github.com/ZeroQI/Absolute-Series-Scanner
PLEXDIR="/var/lib/plexmediaserver/Library/Application Support/Plex Media Server/Scanners"
sudo mkdir -p "$PLEXDIR/Series"
sudo wget -O "$PLEXDIR/Series/Absolute Series Scanner.py" https://raw.githubusercontent.com/ZeroQI/Absolute-Series-Scanner/master/Scanners/Series/Absolute%20Series%20Scanner.py
sudo chown -R plex:plex "$PLEXDIR"
sudo chmod 775 -R "$PLEXDIR"

sudo service plexmediaserver start
