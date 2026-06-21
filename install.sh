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
set -euo pipefail

cd "$(dirname "$0")"

render_template() {
  local template_path="$1"
  local output_path="$2"

  local cmd=(ruby "$(dirname "$0")/tools/render_erb.rb" "$template_path" "$output_path" "$ARG_APPDIR" "$ARG_APPDIR/.ssh")
  if [[ "$ARG_USE_ANOTHER_USER" == true ]]; then
    cmd+=("$ARG_USER" "nogroup")
  fi
  if [[ -n "$WRAP_SUDO" ]]; then
    cmd=("$WRAP_SUDO" "${cmd[@]}")
  fi

  "${cmd[@]}"
}

if [[ "$ARG_USE_CURRENT_DIR" == true ]]; then
  ARG_APPDIR=$(pwd)
fi

if [[ ! -d .ssh ]]; then
  echo "config directory '.ssh' not found"
  echo "Copy 'ssh' to '.ssh' and edit 'config.erb' and 'id_rsa' file"
  exit 1
fi

if [[ ! -f .ssh/config.erb ]]; then
  echo "config file '.ssh/config.erb' not found"
  echo "Copy 'ssh/config.erb' to '.ssh/config.erb' and edit it"
  exit 1
fi

if [[ "$ARG_ALWAYS_YES" != true ]]; then
  echo "Install to $ARG_APPDIR. Continue? (Y/n)"
  read -r l_confirm
  if [[ 'Y' != "$l_confirm" ]]; then
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
  $WRAP_SUDO cp -ar lib "$ARG_APPDIR"
fi

render_template "portfwd.service.erb" "$ARG_APPDIR/portfwd.service"
render_template "ssh/config.erb" "$ARG_APPDIR/.ssh/config"

$WRAP_SUDO chmod -R 700 "$ARG_APPDIR/.ssh"
if [[ -n "$WRAP_SUDO" ]]; then
  if [[ "$ARG_USE_ANOTHER_USER" == true ]]; then
    $WRAP_SUDO chown -R "$ARG_USER":nogroup "$ARG_APPDIR/.ssh"
  fi
fi

$WRAP_SUDO cp "$ARG_APPDIR/portfwd.service" /etc/systemd/system/portfwd.service

$WRAP_SUDO systemctl daemon-reload
$WRAP_SUDO systemctl enable portfwd
$WRAP_SUDO systemctl start portfwd
