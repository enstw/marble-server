#!/system/bin/sh
# agents_setup.sh — install the AI-agent base toolchain inside the chroot.
#
# Installs:
#   - tmux (session persistence + detach/attach — our no-systemd workaround)
#   - Node 24 via NodeSource (OpenClaw and other Node-based agents)
#   - uv via Astral (Hermes and other Python-based agents; user-scope)
#   - /usr/local/bin/tmux-service helper (see scripts/tmux-service.sh)
#
# Idempotent — safe to re-run. Assumes phase 3 is done (the `user` account
# exists; sudo is installed).
#
# Invoke from Android:
#   adb shell su -c 'sh /data/data/com.termux/files/home/agents_setup.sh'

set -e

UBUNTU=/data/data/com.termux/files/home/ubuntu
HELPER_SRC=/data/data/com.termux/files/home/tmux-service.sh

if [ ! -r "$HELPER_SRC" ]; then
    echo "ERROR: $HELPER_SRC missing — push scripts/tmux-service.sh first" >&2
    exit 1
fi

# Stage the helper at /usr/local/bin (in user's default PATH, unlike /sbin).
# /usr/local is dpkg-untouched so the install survives apt upgrades.
install -m 0755 "$HELPER_SRC" "$UBUNTU/usr/local/bin/tmux-service"

exec sh /data/data/com.termux/files/home/start_ubuntu.sh << 'CHROOT_CMD'
set -e

export DEBIAN_FRONTEND=noninteractive

apt-get update
apt-get install -y tmux curl ca-certificates gpg git

# tmux config is owned by ssh_setup.sh because that script runs at boot and
# needs to preserve default-shell, True Color, and mouse settings together.

# Node 24 via NodeSource. Ubuntu 26.04's archive may ship a recent-enough Node
# for OpenClaw (≥22.16), but NodeSource pins us to Node 24 explicitly — the
# version OpenClaw's docs recommend. Skip reinstall if we already have Node 24+
# to keep the script fast on re-runs.
if ! command -v node >/dev/null 2>&1 || ! node -v | grep -qE '^v(2[4-9]|[3-9][0-9])\.'; then
    install -d -m 0755 /etc/apt/keyrings
    curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key \
        | gpg --dearmor -o /etc/apt/keyrings/nodesource.gpg
    chmod 0644 /etc/apt/keyrings/nodesource.gpg
    echo 'deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_24.x nodistro main' \
        > /etc/apt/sources.list.d/nodesource.list
    apt-get update
    apt-get install -y nodejs
fi

# uv installed per-user into ~/.local/bin. Keeps Python dependency graphs out
# of /usr and matches the global "uv everywhere, never pip" preference.
# Ubuntu's default ~/.profile already prepends ~/.local/bin to PATH when that
# dir exists at login time, so no ~/.profile edit needed here — but we create
# the dir up-front to guarantee the login-shell PATH picks it up on the first
# ssh session after install.
su -l user -s /bin/sh <<'USER_CMD'
set -e
mkdir -p "$HOME/.local/bin"
if ! command -v uv >/dev/null 2>&1; then
    curl -LsSf https://astral.sh/uv/install.sh | sh
fi
USER_CMD

echo --- versions ---
tmux -V
node --version
npm --version
su -l user -s /bin/sh -c 'PATH="$HOME/.local/bin:$PATH" uv --version'
echo --- helper ---
ls -l /usr/local/bin/tmux-service
CHROOT_CMD
