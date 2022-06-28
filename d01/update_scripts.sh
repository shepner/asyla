#!/bin/sh
# https://stackoverflow.com/questions/2466735/how-to-sparsely-checkout-only-one-single-file-from-a-git-repository

REPO=shepner/asyla
WORKDIR=~/scripts

# Dont care about any changes
if [ -d $WORKDIR ]; then
  doas rm -R $WORKDIR
fi

# git only the items we care about
git clone --depth 1 --no-checkout --filter=blob:none https://github.com/$REPO.git $WORKDIR
cd $WORKDIR
git checkout master -- `hostname -s`
git checkout master -- docker
git checkout master -- docker2
git checkout master -- compose

# Just in case permissions werent set correctly
find $WORKDIR -name "*.sh" -exec chmod 744 {} \;

mv $WORKDIR/`hostname -s`/*.sh ~

