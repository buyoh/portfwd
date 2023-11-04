#!/bin/bash

ARG_USER=mai-portfwd
ARG_UID=2525

ARG_APPDIR=/opt/mai-portfwd

set -e

cd $(dirname $0)

if [[ ! -d .ssh ]]; then
  echo "config directory '.ssh' not found"
  echo "Copy 'ssh' to '.ssh' and edit 'config' and 'id_rsa' file"
  exit 1
fi

if [[ ! -f .ssh/config ]]; then
  echo "config file '.ssh/config' not found"
  echo "Copy 'ssh/config' to '.ssh/config' and edit it"
  exit 1
fi

if ! id $ARG_USER > /dev/null; then
  echo "User '$ARG_USER' does not exist. Create"
  sudo useradd -u 2525 -g nogroup -M -d /nonexistent -s /usr/sbin/nologin mai-portfwd
fi

echo "Install to $ARG_APPDIR. Continue? (Y/n)"

read l_confirm
if [[ 'Y' != $l_confirm ]]; then
  echo 'abort'
  exit 1
fi

sudo mkdir -p $ARG_APPDIR

sudo cp -ar .ssh $ARG_APPDIR
sudo cp -a portfwd.service $ARG_APPDIR

sudo sed -i "s|[~]/[.]ssh|$ARG_APPDIR/.ssh|g" $ARG_APPDIR/portfwd.service
sudo sed -i "s|[~]/[.]ssh|$ARG_APPDIR/.ssh|g" $ARG_APPDIR/.ssh/config

sudo chmod -R 700 $ARG_APPDIR/.ssh
sudo chown -R $ARG_USER:nogroup $ARG_APPDIR/.ssh

sudo cp $ARG_APPDIR/portfwd.service /etc/systemd/system/portfwd.service

sudo systemctl daemon-reload
sudo systemctl enable portfwd
sudo systemctl start portfwd
