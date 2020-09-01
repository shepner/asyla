#!/bin/sh
# https://stackoverflow.com/questions/2466735/how-to-sparsely-checkout-only-one-single-file-from-a-git-repository

REPO=shepner/asyla
WORKDIR=~/scripts

if [ -d $WORKDIR ]; then
  rm -R $WORKDIR
fi

git clone --depth 1 --no-checkout --filter=blob:none https://github.com/$REPO.git $WORKDIR
cd $WORKDIR
git checkout master -- `hostname -s`

find $WORKDIR -name "*.sh" -exec chmod 744 {} \;

mv $WORKDIR/`hostname -s`/update_scripts.sh ~

