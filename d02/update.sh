#!/bin/sh

doas docker image prune --all -f
doas docker system prune --all -y

doas apk update && doas apk upgrade

