#!/bin/sh
# user account settings

# Remove what little bits of pesky security we have
echo "`id -un` ALL=(ALL) NOPASSWD: ALL" | sudo EDITOR='tee -a' visudo

# Fix groups
sudo groupmod `id -un` -n asyla

# Forward email
echo "`id -un`@asyla.org" > ~/.forward
echo "`id -un`@asyla.org" | sudo tee -a /root/.forward

