#!/bin/sh

# update all of the configs
~./update_scripts.sh

# reload all the containers
~./scripts/docker/traefik/traefik.sh

~./scripts/docker/calibre.sh
~./scripts/docker/booksonic.sh



