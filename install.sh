#!/bin/bash

# --- arguments ---

ARG_USER_GIVEN=${ARG_USER+x}

ARG_USE_ROOT=${ARG_USE_ROOT:-false}
ARG_USER=${ARG_USER:-mai-portfwd}
ARG_APPDIR=${ARG_APPDIR:-/opt/mai-portfwd}
ARG_ALWAYS_YES=${ARG_ALWAYS_YES:-false}
# ruby used by the service at runtime (not the one rendering templates during install).
# It is checked with the invoker's privilege only; whether the service user can run it is found by the startup check.
# Shims of rbenv or asdf do not work, since they depend on HOME and so on of the invoker
ARG_RUBY=${ARG_RUBY:-/usr/bin/ruby}
# for test only: deploy files with the invoker's privilege. Skip sudo, useradd, chown and systemd
ARG_FILES_ONLY_FOR_TEST=${ARG_FILES_ONLY_FOR_TEST:-false}

STARTUP_CHECK_SEC=20

# --- main ---

set -euo pipefail

# files created by this script are private unless a mode is given explicitly
umask 077

obsolete_arg_replacement() {
  case "$1" in
    ARG_USE_SUDO) echo "remove it. sudo is used automatically unless running as root" ;;
    ARG_USE_ANOTHER_USER) echo "use ARG_USE_ROOT=true instead of ARG_USE_ANOTHER_USER=false" ;;
    ARG_UID) echo "remove it. The UID is allocated automatically" ;;
    ARG_USE_CURRENT_DIR) echo "removed. Run lib/main.rb directly. Do not set ARG_APPDIR to this repository" ;;
    ARG_INSTALL_SYSTEMD) echo "use ARG_FILES_ONLY_FOR_TEST=true (for test only)" ;;
    ARG_STARTUP_CHECK_SEC) echo "remove it. The check waits ${STARTUP_CHECK_SEC}s" ;;
  esac
}
for name in ARG_USE_SUDO ARG_USE_ANOTHER_USER ARG_UID ARG_USE_CURRENT_DIR ARG_INSTALL_SYSTEMD ARG_STARTUP_CHECK_SEC; do
  if [[ -n "${!name+x}" ]]; then
    echo "$name is no longer supported: $(obsolete_arg_replacement "$name")"
    exit 1
  fi
done
for name in ARG_USE_ROOT ARG_ALWAYS_YES ARG_FILES_ONLY_FOR_TEST; do
  if [[ "${!name}" != true && "${!name}" != false ]]; then
    echo "$name must be 'true' or 'false': '${!name}'"
    exit 1
  fi
done
if [[ "$ARG_APPDIR" != /* ]]; then
  echo "ARG_APPDIR must be an absolute path: '$ARG_APPDIR'"
  exit 1
fi
# the paths are embedded in the systemd unit and the ssh config without escaping:
# a space splits ExecStart, '%' is a specifier of systemd, and a newline injects a directive
for name in ARG_APPDIR ARG_RUBY; do
  if [[ ! "${!name}" =~ ^/[A-Za-z0-9._/-]*$ ]]; then
    echo "$name must be an absolute path of letters, digits, '.', '_', '/' and '-': '${!name}'"
    exit 1
  fi
done
# a trailing slash makes `test -L` follow a symbolic link
while [[ "$ARG_APPDIR" == */ && "$ARG_APPDIR" != / ]]; do
  ARG_APPDIR=${ARG_APPDIR%/}
done
if [[ ! "$ARG_USER" =~ ^[A-Za-z_][A-Za-z0-9._-]*\$?$ ]]; then
  echo "ARG_USER is not a valid user name: '$ARG_USER'"
  exit 1
fi
if [[ "$ARG_USE_ROOT" == true && -n "$ARG_USER_GIVEN" ]]; then
  echo "ARG_USER cannot be used with ARG_USE_ROOT=true"
  exit 1
fi

WRAP_SUDO=
if [[ "$ARG_FILES_ONLY_FOR_TEST" != true && $EUID -ne 0 ]]; then
  WRAP_SUDO=sudo
  if ! command -v sudo > /dev/null; then
    echo "sudo not found. Run as root or install sudo"
    exit 1
  fi
fi

# whether the service runs as ARG_USER and the files are owned by it
USE_SERVICE_USER=false
if [[ "$ARG_USE_ROOT" != true && "$ARG_FILES_ONLY_FOR_TEST" != true ]]; then
  USE_SERVICE_USER=true
fi

if [[ "$ARG_FILES_ONLY_FOR_TEST" == true ]]; then
  echo "TEST MODE: deploy files only, as the current user. Skip sudo, useradd, chown and systemd"
fi

# paths below are relative to the source directory
cd "$(dirname "$0")"

if [[ "$(realpath -m "$ARG_APPDIR")" == "$(pwd -P)" ]]; then
  echo "ARG_APPDIR must not be the source directory: $ARG_APPDIR"
  exit 1
fi

render_template() {
  local template_path="$1"
  local output_path="$2"

  local cmd=(ruby tools/render_erb.rb "$template_path" "$output_path"
    "app_dir=$ARG_APPDIR" "ssh_dir=$ARG_APPDIR/.ssh" "ruby=$ARG_RUBY")
  if [[ "$USE_SERVICE_USER" == true ]]; then
    cmd+=("user=$ARG_USER" "group=$SERVICE_GROUP")
  else
    cmd+=("user=root" "group=root")
  fi
  if [[ -n "$WRAP_SUDO" ]]; then
    cmd=("$WRAP_SUDO" "${cmd[@]}")
  fi

  "${cmd[@]}"
}

confirm() {
  local message="$1"
  local answer

  echo "$message"
  if [[ "$ARG_ALWAYS_YES" == true ]]; then
    return
  fi
  echo "Continue? (y/N)"
  # EOF (e.g. no terminal) leaves answer empty, which is a "no".
  # a last line without a newline makes read fail, but answer keeps it
  read -r answer || true
  if [[ ! "$answer" =~ ^[Yy]([Ee][Ss])?$ ]]; then
    echo 'abort'
    exit 1
  fi
}

# prints SYS_UID_MAX of login.defs. Falls back to UID_MIN - 1 as useradd does, or 999
sys_uid_max() {
  local file value

  for file in /etc/login.defs /usr/etc/login.defs; do
    [[ -r "$file" ]] || continue
    # decimal only: a leading zero would be octal for bash
    value=$(sed -n 's/^[[:space:]]*SYS_UID_MAX[[:space:]][[:space:]]*\([1-9][0-9]*\)[[:space:]]*$/\1/p' "$file" | tail -n 1)
    if [[ -n "$value" ]]; then
      echo "$value"
      return
    fi
    value=$(sed -n 's/^[[:space:]]*UID_MIN[[:space:]][[:space:]]*\([1-9][0-9]*\)[[:space:]]*$/\1/p' "$file" | tail -n 1)
    if [[ -n "$value" ]]; then
      echo $((value - 1))
      return
    fi
    break
  done
  echo 999
}

# the primary group of ARG_USER. Set after the user is created
SERVICE_GROUP=
# owner options for `install`. Omitted when the files are owned by the invoking user (root, or the tester)
SSH_OWNER_OPTS=()
CODE_OWNER_OPTS=()
if [[ "$USE_SERVICE_USER" == true ]]; then
  CODE_OWNER_OPTS=(-o root -g root)
fi

# install the regular files directly under .ssh (except templates and generated files) into dest_dir.
# config.rb is not installed: the service reads config.yml generated from it
install_ssh_files() {
  local dest_dir="$1"
  local file

  for file in .ssh/*; do
    [[ -f "$file" ]] || continue
    case "$(basename "$file")" in
      config.erb | config | config.rb | config.yml) continue ;;
    esac
    $WRAP_SUDO install -m 600 "${SSH_OWNER_OPTS[@]}" "$file" "$dest_dir/"
  done
}

render_ssh_config() {
  local dest_dir="$1"

  render_template ".ssh/config.erb" "$dest_dir/config"
  $WRAP_SUDO chmod 600 "$dest_dir/config"
  if [[ "$USE_SERVICE_USER" == true ]]; then
    $WRAP_SUDO chown "$ARG_USER:$SERVICE_GROUP" "$dest_dir/config"
  fi
}

# restore a directory left half-swapped by an interrupted run, and remove staging leftovers
cleanup_staging() {
  local name
  for name in .ssh lib; do
    if [[ ! -e "$ARG_APPDIR/$name" && -e "$ARG_APPDIR/$name.old" ]]; then
      $WRAP_SUDO mv "$ARG_APPDIR/$name.old" "$ARG_APPDIR/$name"
    fi
    $WRAP_SUDO rm -rf "$ARG_APPDIR/$name.new" "$ARG_APPDIR/$name.old"
  done
}

swap_dir() {
  local name="$1"

  if [[ -e "$ARG_APPDIR/$name" ]]; then
    $WRAP_SUDO mv "$ARG_APPDIR/$name" "$ARG_APPDIR/$name.old"
  fi
  $WRAP_SUDO mv "$ARG_APPDIR/$name.new" "$ARG_APPDIR/$name"
  $WRAP_SUDO rm -rf "$ARG_APPDIR/$name.old"
}

# prints the state of the directory $1: symlink, absent, not-directory, empty, installed, legacy or unknown.
# run as a single privileged command, so that a failure of sudo itself is not taken as a result of the check
APPDIR_STATE_SCRIPT='
  d=$1
  if [ -L "$d" ]; then echo symlink; exit 0; fi
  if [ ! -e "$d" ]; then echo absent; exit 0; fi
  if [ ! -d "$d" ]; then echo not-directory; exit 0; fi
  # empty, or only leftovers of an interrupted first install
  entries=$(find "$d" -mindepth 1 -maxdepth 1 ! -name .ssh.new ! -name lib.new -print -quit) || exit 1
  if [ -z "$entries" ]; then echo empty; exit 0; fi
  if [ -f "$d/version" ] && head -n 1 "$d/version" | grep -Eqx "[0-9a-f]{40}|[0-9a-f]{64}|unknown"; then
    echo installed; exit 0
  fi
  # installed by older versions without the version file, and not another working copy
  if [ ! -e "$d/.git" ] && [ ! -e "$d/install.sh" ] \
    && { { [ -f "$d/lib/main.rb" ] && [ -f "$d/.ssh/config.rb" ]; } || [ -f "$d/portfwd.service" ]; }; then
    echo legacy; exit 0
  fi
  echo unknown
'

# check that ARG_APPDIR is absent, empty, or was installed by this script. Abort otherwise
check_appdir() {
  APPDIR_STATE=$($WRAP_SUDO sh -c "$APPDIR_STATE_SCRIPT" sh "$ARG_APPDIR") || {
    echo "Failed to check '$ARG_APPDIR'"
    exit 1
  }
  case "$APPDIR_STATE" in
    absent | empty | installed | legacy) ;;
    symlink)
      echo "'$ARG_APPDIR' is a symbolic link. Specify the real path"
      exit 1
      ;;
    not-directory)
      echo "'$ARG_APPDIR' is not a directory"
      exit 1
      ;;
    unknown)
      echo "'$ARG_APPDIR' is not empty and was not installed by this script. Abort"
      echo "If it was installed by an older version, mark it and rerun:"
      echo "  echo unknown | sudo tee '$ARG_APPDIR/version'"
      exit 1
      ;;
    *)
      echo "Failed to check '$ARG_APPDIR': $APPDIR_STATE"
      exit 1
      ;;
  esac
}

TMP_VERSION_FILE=
write_version() {
  TMP_VERSION_FILE=$(mktemp)
  printf '%s\n' "$SOURCE_VERSION" > "$TMP_VERSION_FILE"
  $WRAP_SUDO install -T -m 644 "${CODE_OWNER_OPTS[@]}" "$TMP_VERSION_FILE" "$ARG_APPDIR/version"
  rm -f "$TMP_VERSION_FILE"
  TMP_VERSION_FILE=
}

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

if [[ ! -f .ssh/config.rb ]]; then
  echo "config file '.ssh/config.rb' not found"
  echo "Copy 'ssh/config.rb' to '.ssh/config.rb' and edit it"
  exit 1
fi

if [[ "$ARG_FILES_ONLY_FOR_TEST" != true && ( "$ARG_RUBY" != /* || ! -x "$ARG_RUBY" ) ]]; then
  echo "ruby '$ARG_RUBY' is not an absolute path to an executable"
  echo "Set ARG_RUBY to the ruby the service should run with"
  exit 1
fi
# the service reads config.yml. libyaml may be packaged separately from ruby
if [[ "$ARG_FILES_ONLY_FOR_TEST" != true ]] && ! "$ARG_RUBY" -ryaml -e '' > /dev/null 2>&1; then
  echo "ruby '$ARG_RUBY' cannot load yaml. Install libyaml for it"
  exit 1
fi
# the timeouts of TCPSocket.new used by the service
if [[ "$ARG_FILES_ONLY_FOR_TEST" != true ]] \
  && ! "$ARG_RUBY" -e 'exit(Gem::Version.new(RUBY_VERSION) >= Gem::Version.new("3.0"))' > /dev/null 2>&1; then
  echo "ruby '$ARG_RUBY' is older than 3.0, which the service requires"
  exit 1
fi

# evaluate config.rb with the invoker's privilege (no sudo) before modifying anything.
# config.rb is not installed and is never evaluated by the service.
# a private directory, so that other users cannot take the name of the tool's temporary file
TMP_CONFIG_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_CONFIG_DIR"' EXIT
TMP_CONFIG_YML=$TMP_CONFIG_DIR/config.yml
# read back in another process, since config.rb can affect the tool's own process (e.g. `exit 0`)
if ! ruby tools/generate_config.rb .ssh/config.rb "$TMP_CONFIG_YML" \
  || ! ruby -r ./lib/node_config -e 'NodeConfig.parse_file(ARGV[0])' "$TMP_CONFIG_YML"; then
  echo "Failed to generate config.yml from '.ssh/config.rb'"
  exit 1
fi

# an existing user owns the private key and runs the service. Created after the confirmation otherwise
SERVICE_USER_NOT_SYSTEM=false
if [[ "$USE_SERVICE_USER" == true ]]; then
  if l_uid=$(id -u "$ARG_USER" 2> /dev/null); then
    if ! l_group=$(id -gn "$ARG_USER" 2> /dev/null); then
      echo "The primary group of '$ARG_USER' has no name. Fix the user or use another ARG_USER"
      exit 1
    fi
    echo "Service user: $ARG_USER (uid $l_uid, group $l_group)"
    if [[ "$l_uid" == 0 ]]; then
      echo "ARG_USER '$ARG_USER' is root. Use ARG_USE_ROOT=true to run the service as root"
      exit 1
    fi
    if ((l_uid > $(sys_uid_max))); then
      SERVICE_USER_NOT_SYSTEM=true
    fi
  elif getent group "$ARG_USER" > /dev/null; then
    # useradd -U fails
    echo "User '$ARG_USER' does not exist, but group '$ARG_USER' exists"
    echo "Create the user with the group (useradd --system -g '$ARG_USER' ...), or use another ARG_USER"
    exit 1
  fi
fi

check_appdir

# commit hash and commit time of the source, or "unknown" if not available
SOURCE_VERSION=unknown
if [[ "$(git -c safe.directory='*' rev-parse --show-toplevel 2> /dev/null)" == "$(pwd -P)" ]] \
  && l_version=$(git -c safe.directory='*' log -1 --format='%H%n%cI' 2> /dev/null); then
  SOURCE_VERSION=$l_version
fi

confirm "Install to $ARG_APPDIR."

if [[ "$ARG_USE_ROOT" == true && "$ARG_FILES_ONLY_FOR_TEST" != true ]]; then
  confirm "WARNING: The service will run as root (ARG_USE_ROOT=true)."
fi

if [[ "$SERVICE_USER_NOT_SYSTEM" == true ]]; then
  confirm "WARNING: '$ARG_USER' is not a system user. It will own the private key and run the service."
fi

if [[ "$USE_SERVICE_USER" == true ]]; then
  if ! id "$ARG_USER" > /dev/null 2>&1; then
    echo "User '$ARG_USER' does not exist. Create"
    # -U: a group of the same name. nogroup does not exist on some distributions
    $WRAP_SUDO useradd --system -U -M -d /nonexistent -s /usr/sbin/nologin "$ARG_USER"
  fi
  SERVICE_GROUP=$(id -gn "$ARG_USER")
  SSH_OWNER_OPTS=(-o "$ARG_USER" -g "$SERVICE_GROUP")
fi

TMP_UNIT_FILE=
on_exit() {
  if [[ -n "$TMP_UNIT_FILE" ]]; then
    $WRAP_SUDO rm -f "$TMP_UNIT_FILE"
  fi
  if [[ -n "$TMP_VERSION_FILE" ]]; then
    rm -f "$TMP_VERSION_FILE"
  fi
  rm -rf "$TMP_CONFIG_DIR"
  cleanup_staging
}
trap on_exit EXIT

$WRAP_SUDO install -d -m 755 "${CODE_OWNER_OPTS[@]}" "$ARG_APPDIR"
# mark the directory first, so that a first install interrupted below can be resumed
if [[ "$APPDIR_STATE" != installed ]]; then
  write_version
fi
cleanup_staging
# generated by older versions of this script
$WRAP_SUDO rm -f "$ARG_APPDIR/portfwd.service"

$WRAP_SUDO install -d -m 700 "${SSH_OWNER_OPTS[@]}" "$ARG_APPDIR/.ssh.new"
install_ssh_files "$ARG_APPDIR/.ssh.new"
render_ssh_config "$ARG_APPDIR/.ssh.new"
$WRAP_SUDO install -T -m 600 "${SSH_OWNER_OPTS[@]}" "$TMP_CONFIG_YML" "$ARG_APPDIR/.ssh.new/config.yml"

$WRAP_SUDO install -d -m 755 "${CODE_OWNER_OPTS[@]}" "$ARG_APPDIR/lib.new"
$WRAP_SUDO install -m 644 "${CODE_OWNER_OPTS[@]}" lib/*.rb "$ARG_APPDIR/lib.new/"

swap_dir .ssh
swap_dir lib
write_version

if [[ "$ARG_FILES_ONLY_FOR_TEST" == true ]]; then
  echo "Skip systemd setup"
  exit 0
fi

# created by root: rendering as root into a file owned by another user in /tmp fails with fs.protected_regular
TMP_UNIT_FILE=$($WRAP_SUDO mktemp)
render_template "portfwd.service.erb" "$TMP_UNIT_FILE"
$WRAP_SUDO install -m 644 "$TMP_UNIT_FILE" /etc/systemd/system/portfwd.service

$WRAP_SUDO systemctl daemon-reload
$WRAP_SUDO systemctl enable portfwd
$WRAP_SUDO systemctl restart portfwd

echo "Waiting ${STARTUP_CHECK_SEC}s to check the service is running"
sleep "$STARTUP_CHECK_SEC"
if ! $WRAP_SUDO systemctl is-active --quiet portfwd \
  || [[ "$($WRAP_SUDO systemctl show -p NRestarts --value portfwd)" != 0 ]]; then
  echo "portfwd failed to start. See: journalctl -u portfwd"
  echo "The files are installed and the service is registered. It keeps restarting until it succeeds"
  exit 1
fi
echo "portfwd is running"
