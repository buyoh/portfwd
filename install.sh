#!/bin/bash

# --- arguments ---

ARG_USE_ANOTHER_USER=${ARG_USE_ANOTHER_USER:-true}
ARG_USER=${ARG_USER:-mai-portfwd}
ARG_UID=${ARG_UID:-2525}

ARG_USE_SUDO=${ARG_USE_SUDO:-true}
ARG_ALWAYS_YES=${ARG_ALWAYS_YES:-false}

ARG_USE_CURRENT_DIR=${ARG_USE_CURRENT_DIR:-false}
ARG_APPDIR=${ARG_APPDIR:-/opt/mai-portfwd}

# --- main ---

WRAP_SUDO=
if [[ "$ARG_USE_SUDO" == true ]]; then
  WRAP_SUDO=sudo
fi
set -e

cd $(dirname $0)

if [[ "$ARG_USE_CURRENT_DIR" == true ]]; then
  ARG_APPDIR=$(pwd)
fi

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

if [[ "$ARG_ALWAYS_YES" != true ]]; then
  echo "Install to $ARG_APPDIR. Continue? (Y/n)"
  read l_confirm
  if [[ 'Y' != $l_confirm ]]; then
    echo 'abort'
    exit 1
  fi
fi

if [[ "$ARG_USE_ANOTHER_USER" == true ]]; then
  if ! id "$ARG_USER" > /dev/null; then
    echo "User '$ARG_USER' does not exist. Create"
    $WRAP_SUDO useradd -u "$ARG_UID" -g nogroup -M -d /nonexistent -s /usr/sbin/nologin "$ARG_USER"
  fi
fi


if [[ "$ARG_USE_CURRENT_DIR" == true ]]; then
  echo "Using current directory as appdir. Skip copy"
else
  $WRAP_SUDO mkdir -p "$ARG_APPDIR"

  $WRAP_SUDO cp -ar .ssh "$ARG_APPDIR"
  $WRAP_SUDO cp -a portfwd.service "$ARG_APPDIR"
  $WRAP_SUDO cp -ar lib "$ARG_APPDIR"
fi

$WRAP_SUDO sed -i "s|[~]/lib|$ARG_APPDIR/lib|g" "$ARG_APPDIR/portfwd.service"
$WRAP_SUDO sed -i "s|[~]/[.]ssh|$ARG_APPDIR/.ssh|g" "$ARG_APPDIR/portfwd.service"
$WRAP_SUDO sed -i "s|[~]/[.]ssh|$ARG_APPDIR/.ssh|g" "$ARG_APPDIR/.ssh/config"

$WRAP_SUDO chmod -R 700 "$ARG_APPDIR/.ssh"
if [ "$WRAP_SUDO" != "" ]; then
  if [[ "$ARG_USE_ANOTHER_USER" == true ]]; then
    $WRAP_SUDO chown -R $ARG_USER:nogroup "$ARG_APPDIR/.ssh"
  fi
fi

$WRAP_SUDO cp "$ARG_APPDIR/portfwd.service" /etc/systemd/system/portfwd.service

$WRAP_SUDO systemctl daemon-reload
$WRAP_SUDO systemctl enable portfwd
$WRAP_SUDO systemctl start portfwd
