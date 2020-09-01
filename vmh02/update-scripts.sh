#!/bin/sh
# https://stackoverflow.com/questions/2466735/how-to-sparsely-checkout-only-one-single-file-from-a-git-repository

git clone --depth 1 --no-checkout --filter=blob:none https://github.com/shepner/asyla.git ~/scripts

cd ~/scripts
git checkout master -- `hostname -s`
git checkout master -- vm

