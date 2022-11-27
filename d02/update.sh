#!/bin/sh

doas docker image prune --all -f
doas docker system prune --all -f

doas apk update && doas apk upgrade

