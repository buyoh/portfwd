# PORTFWD

systemd service to create a remote forwarding connection from server to client

## How to use

1. Copy `ssh` directory to `.ssh`
2. Update `.ssh/config.erb`, `.ssh/config.rb` and `.ssh/id_rsa`, and more.
3. Run `install.sh`

`.ssh/config.rb` declares the connections. `install.sh` evaluates it with the invoker's privilege and installs the generated `config.yml` instead of `config.rb`. The service reads only `config.yml` and never evaluates `config.rb`.

After changing `config.rb`, rerun `install.sh` (or `tools/generate_config.rb` for the working copy). Do not edit the installed `config.yml` directly: it is a generated file.

The host names in `config.rb` (`host` of `p_conn`) must match `[A-Za-z0-9][A-Za-z0-9_-]*`, and `p_conn` accepts only the keys `host` and `check_tcps`.

`check_tcps` lists the TCP ports on this machine which can be connected to while the connection is up. The service checks them after starting ssh and periodically, and restarts the connections if any of them is closed. Usually they are the `LocalForward` ports of the Host. See the comments in `ssh/config.rb`.

## Register host keys

The sample config uses `StrictHostKeyChecking yes` with `.ssh/known_hosts`, which is read-only for the service. `ssh/known_hosts` is empty, so register the host key of each server before running `install.sh`. Otherwise ssh fails with `Host key verification failed` and the service keeps restarting.

```sh
ssh-keyscan -p 10022 example.com > hostkey.tmp   # the Port and HostName of config.erb
ssh-keygen -lf hostkey.tmp                       # compare the fingerprint with the one the server administrator gives you
cat hostkey.tmp >> .ssh/known_hosts
```

Check the fingerprint through a trusted channel (for example, run `ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub` on the server). Do not disable the verification with `StrictHostKeyChecking no` or `UserKnownHostsFile /dev/null`: that allows a man-in-the-middle attack.

## Requirements

- Linux with systemd
- The ruby given by `ARG_RUBY` (3.0 or later, able to load yaml). `install.sh` checks both
- `install.sh` also runs other ruby: the `ruby` in the invoker's `PATH` evaluates `config.rb`, and the `ruby` in the `secure_path` of sudo renders the templates (a ruby of rbenv and so on is not found by sudo)
- OpenSSH client
- `sudo` (unless running as root) and `useradd`

## Service user

Unless `ARG_USE_ROOT=true`, the service runs as `ARG_USER`, which owns the files under `.ssh`.

- A new user is created by `useradd --system -U`, with a group of the same name.
- An existing user is used with its primary group. `install.sh` refuses root, and asks for a confirmation if it is not a system user (its UID is larger than `SYS_UID_MAX` of `/etc/login.defs`).
- If the user does not exist but a group of the same name does, `install.sh` aborts, since `useradd -U` fails. Create the user with the group, or use another `ARG_USER`.

## Install options

`install.sh` reads the following environment variables.

| Variable | Default | Description |
|---|---|---|
| `ARG_USE_ROOT` | `false` | `true` runs the service as root instead of a dedicated user |
| `ARG_USER` | `mai-portfwd` | The dedicated user that runs the service. Created if missing. Letters, digits, `.`, `_` and `-` (not starting with `-`, `.` or a digit), optionally ending with `$`. Cannot be used with `ARG_USE_ROOT=true` |
| `ARG_APPDIR` | `/opt/mai-portfwd` | Install destination. An absolute path of letters, digits, `.`, `_`, `/` and `-`, not a symbolic link. Must be absent, empty, or a directory installed by `install.sh` |
| `ARG_ALWAYS_YES` | `false` | `true` skips the confirmation prompts |
| `ARG_RUBY` | `/usr/bin/ruby` | The ruby the service runs with. An absolute path of letters, digits, `.`, `_`, `/` and `-` |
| `ARG_FILES_ONLY_FOR_TEST` | `false` | For tests only. Deploys the files as the current user, and skips sudo, user creation, ownership and systemd |

`sudo` is used automatically unless `install.sh` runs as root.

The following variables were removed. `install.sh` aborts if any of them is set, even to its old default value.

| Removed variable | Replacement |
|---|---|
| `ARG_USE_SUDO` | None. `sudo` is used automatically unless running as root |
| `ARG_USE_ANOTHER_USER=false` | `ARG_USE_ROOT=true` |
| `ARG_UID` | None. The UID is allocated automatically. An existing user is kept as is |
| `ARG_USE_CURRENT_DIR` | None. See "Run from the working copy" |
| `ARG_INSTALL_SYSTEMD=false` | `ARG_FILES_ONLY_FOR_TEST=true` (for tests only) |
| `ARG_STARTUP_CHECK_SEC` | None. The startup check waits 20 seconds |

The systemd unit is named `portfwd`, so only one copy can be installed on a host. Running `install.sh` again with another `ARG_APPDIR` switches the service to it, and leaves the previous `ARG_APPDIR`.

## Uninstall

```sh
sudo systemctl disable --now portfwd
sudo rm /etc/systemd/system/portfwd.service
sudo systemctl daemon-reload
sudo rm -rf /opt/mai-portfwd  # ARG_APPDIR
sudo userdel mai-portfwd      # ARG_USER. Only if it was created by install.sh. Its group is removed too if it has no other members
```

## Installed version

`install.sh` writes the commit hash and commit time of the source to `$ARG_APPDIR/version`, or `unknown` if the source is not a git working copy.

```sh
cat /opt/mai-portfwd/version
```

`install.sh` refuses to overwrite a non-empty `ARG_APPDIR` that it did not install. If the directory was installed by an older version of `install.sh` that is not detected, mark it and rerun:

```sh
echo unknown | sudo tee /opt/mai-portfwd/version
```

## Run from the working copy

Do not set `ARG_APPDIR` to the working copy. Run the service directly instead:

```sh
ruby tools/render_erb.rb .ssh/config.erb .ssh/config "app_dir=$PWD" "ssh_dir=$PWD/.ssh" \
  && ruby tools/generate_config.rb .ssh/config.rb .ssh/config.yml \
  && ruby lib/main.rb .ssh
```
