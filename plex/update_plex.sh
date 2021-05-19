#!/bin/sh

# https://support.plex.tv/articles/235974187-enable-repository-updating-for-supported-linux-server-distributions/
echo deb https://downloads.plex.tv/repo/deb public main | sudo tee /etc/apt/sources.list.d/plexmediaserver.list
curl https://downloads.plex.tv/plex-keys/PlexSign.key | sudo apt-key add -
sudo apt-get update


sudo service plexmediaserver stop

sudo apt-get -y upgrade plexmediaserver

# https://github.com/ZeroQI/Absolute-Series-Scanner
PLEXDIR="/var/lib/plexmediaserver/Library/Application Support/Plex Media Server/Scanners"
sudo mkdir -p "$PLEXDIR/Series"
sudo wget -O "$PLEXDIR/Series/Absolute Series Scanner.py" https://raw.githubusercontent.com/ZeroQI/Absolute-Series-Scanner/master/Scanners/Series/Absolute%20Series%20Scanner.py
sudo chown -R plex:plex "$PLEXDIR"
sudo chmod 775 -R "$PLEXDIR"

sudo service plexmediaserver start
