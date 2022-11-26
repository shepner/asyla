# Plex migration notes

Notes about migrating from Plex on an Ubuntu server to a Docker container on Alpine.  The only real reason to do so would be to simplify maintenance. In particular, Ubuntu Server is bloated and constantly needs patched.  Plex also updates frequently.  Using Alpine with a containerized instance of Plex solves both of these issues.

When running Plex in a container, you will likely want to run it on the host network.  This is partially because of the many obscure ports it uses but also because of how the [SiliconDust](https://www.silicondust.com/) HDHomeRun receivers operate (**must** be on the same subnet).

Plex uses a database to operate so you cant use NFS to store its files.  In this case they will be stored on an iSCSI disk with the path `/mnt/iscsi/plex`.  The instructions are elswhere for setting that up.

On Ubuntu Linux, Plex stores its files/config in `/var/lib/plexmediaserver`.  These need to be copied by root to the new destination.  They are quite large.  And, if the migration doesnt go well, you want to maintain the integrity of the original server.

Be sure to SHUT DOWN THE OLD SERVER BEFORE RUNNING THE NEW ONE.

Once everything has been copied over, run the Plex Docker container which is documented elsewhere

Also, DO NOT CHANGE THE MEDIA PATH!  This will break the paths in the Plex database and could trash your data.

---

Install rsync on the new Alpine host:

``` shell
doas apk add rsync
```

!!!NOTE
  The following instructions came from [here](https://www.ustrem.org/en/articles/rsync-over-ssh-as-root-en/)

On the old Ubuntu server, setup sudo access 
``` shell
sudo visudo

# Add the following line to the end of the file:
# shepner ALL=NOPASSWD:/usr/bin/rsync
```

On the old Ubuntu server, stop Plex and check that it is *NOT* running:

``` shell
sudo service plexmediaserver stop
ps axwwwww | grep plex
```

From the new Alpine host, run rsync (WARNING SLOW):

``` shell
# Test that it will work
#doas rsync --dry-run -v -a -e "ssh" --rsync-path="sudo rsync" shepner@plex:/var/lib/plexmediaserver /mnt/iscsi/plex
doas rsync --progress -a -e "ssh" --rsync-path="sudo rsync" shepner@plex:/var/lib/plexmediaserver /mnt/iscsi/plex
```

