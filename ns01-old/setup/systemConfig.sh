#!/bin/sh


# Patch the system
apk update && apk upgrade


# set the tz
# https://wiki.alpinelinux.org/wiki/Setting_the_timezone
apk update \
  && apk add tzdata \
  && cp /usr/share/zoneinfo/America/Chicago /etc/localtime \
  && echo "America/Chicago" > /etc/timezone \
  && apk del tzdata


# Install sshd
# https://wiki.alpinelinux.org/wiki/Setting_up_a_SSH_server
apk update \
  && apk add openssh \
  && rc-update add sshd \
  && /etc/init.d/sshd start


# Forward log messages
# increase log size and history
# https://wiki.alpinelinux.org/wiki/Syslog
cat > /etc/conf.d/syslog << EOF
#SYSLOGD_OPTS="-t -L -R 10.0.0.73"
SYSLOGD_OPTS="-t -s 2048 -b 10 -L -R 10.0.0.73"
EOF
rc-service syslog restart


# Install dnsmasq and webproc binary
# https://dnsmasq.org/
# https://github.com/jpillora/webproc/
apk update \
  && apk add --no-cache dnsmasq \
  && apk add --no-cache --virtual .build-deps curl bash \
  && cd /usr/local/bin; curl https://i.jpillora.com/webproc | bash \
  && apk del .build-deps


# set things to run:
# https://devops.md/en/howto/how-to-enable-and-start-services-on-alpine-linux
# rc-status --list
# rc-service --list

cat >> /etc/local.d/webproc.start << EOF
#!/bin/sh

# DNS and DHCP
#webproc \
#  --port 8053 \
#  --configuration-file /mnt/hosts \
#  --configuration-file /mnt/resolv.conf \
#  --configuration-file /mnt/dnsmasq.leases \
#  --configuration-file /mnt/config//dnsmasq_combined.conf \
#  dnsmasq \
#    --no-daemon \
#    --conf-file=/mnt/config/dnsmasq_combined.conf \
#  &

# DNS only
webproc \
  --port 8053 \
  --configuration-file /mnt/hosts \
  --configuration-file /mnt/resolv.conf \
  --configuration-file /mnt/dnsmasq.leases \
  --configuration-file /mnt/config/dnsmasq.conf \
  dnsmasq \
    --no-daemon \
    --conf-file=/mnt/config/dnsmasq.conf \
  &

# DHCP only
#webproc \
#  --port 8053 \
#  --configuration-file /mnt/hosts \
#  --configuration-file /mnt/resolv.conf \
#  --configuration-file /mnt/dnsmasq.leases \
#  --configuration-file /mnt/config/dnsmasq_dhcp.conf \
#  dnsmasq \
#    --no-daemon \
#    --conf-file=/mnt/configdnsmasq_dhcp.conf \
#  &

EOF
chmod 754 /etc/local.d/webproc.start

rc-update add local default
rc-service local start


