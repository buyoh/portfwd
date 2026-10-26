# PORTFWD

systemd service to create a remote forwarding connection from server to client

## How to use

1. Copy `ssh` directory to `.ssh`
2. Update `.ssh/config.erb`, `.ssh/config.rb` and `.ssh/id_rsa`, and more.
3. Run `install.sh`

`.ssh/config.rb` declares the connections. `install.sh` evaluates it with the invoker's privilege and installs the generated `config.yml` instead of `config.rb`. The service reads only `config.yml` and never evaluates `config.rb`.

After changing `config.rb`, rerun `install.sh` (or `tools/generate_config.rb` for the working copy). Do not edit the installed `config.yml` directly: it is a generated file.

The host names in `config.rb` (`host` of `p_conn`) must match `[A-Za-z0-9][A-Za-z0-9_-]*`, and `p_conn` accepts only the keys `host` and `check_tcps`.

## Install options

`install.sh` reads the following environment variables.

| Variable | Default | Description |
|---|---|---|
| `ARG_USE_ROOT` | `false` | `true` runs the service as root instead of a dedicated user |
| `ARG_USER` | `mai-portfwd` | The dedicated user that runs the service. Created if missing. Letters, digits, `.`, `_` and `-` (not starting with `-`, `.` or a digit), optionally ending with `$`. Cannot be used with `ARG_USE_ROOT=true` |
| `ARG_APPDIR` | `/opt/mai-portfwd` | Install destination. An absolute path, not a symbolic link. Must be absent, empty, or a directory installed by `install.sh` |
| `ARG_ALWAYS_YES` | `false` | `true` skips the confirmation prompts |
| `ARG_RUBY` | `/usr/bin/ruby` | The ruby the service runs with |
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
