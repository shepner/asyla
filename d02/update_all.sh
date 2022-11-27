#!/bin/sh

~/update_scripts.sh

doas docker pull ghcr.io/linuxserver/plex:latest

~/update.sh


