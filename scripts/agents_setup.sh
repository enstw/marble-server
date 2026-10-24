#!/system/bin/sh
# agents_setup.sh — install the AI-agent base toolchain inside the chroot.
#
# Installs:
#   - tmux (session persistence + detach/attach — our no-systemd workaround)
#   - pnpm + Node 24 (OpenClaw and other Node-based agents; user-scope)
#   - uv via Astral (Hermes and other Python-based agents; user-scope)
#   - /usr/local/bin/tmux-service helper (see scripts/tmux-service.sh)
#
# The run-as helper that 50-agents.hook uses to drop to `user` is a generic
# hook helper and is installed by ssh_setup.sh (baseline provisioning), not
# here — see scripts/run-as.sh.
#
# Idempotent — safe to re-run. Assumes phase 3 is done (the `user` account
# exists; sudo is installed).
#
# Invoke from Android:
#   adb shell su -c 'sh /data/data/com.termux/files/home/agents_setup.sh'

set -e

UBUNTU=/data/data/com.termux/files/home/ubuntu
HELPER_SRC=/data/data/com.termux/files/home/tmux-service.sh
AGENTS_HOOK=/data/data/com.termux/files/home/50-agents.hook

if [ ! -r "$HELPER_SRC" ]; then
    echo "ERROR: $HELPER_SRC missing — push scripts/tmux-service.sh first" >&2
    exit 1
fi
if [ ! -r "$AGENTS_HOOK" ]; then
    echo "ERROR: $AGENTS_HOOK missing — push scripts/host-hooks/50-agents.hook first" >&2
    exit 1
fi

# Stage the tmux-service helper at /usr/local/bin (in user's default PATH,
# unlike /sbin). /usr/local is dpkg-untouched so the install survives apt
# upgrades. (run-as is deployed by ssh_setup.sh — see header.)
install -m 0755 "$HELPER_SRC" "$UBUNTU/usr/local/bin/tmux-service"

# Deploy the agents boot hook DISABLED by default (.disabled suffix) so boot
# stays quiet until you opt in. Enable with:
#   sudo mv /etc/host-hooks/50-agents.hook.disabled /etc/host-hooks/50-agents.hook
# Only deploy if neither the enabled nor disabled copy exists yet, so re-running
# agents_setup.sh never clobbers an already-enabled hook back to disabled.
install -d -m 0755 "$UBUNTU/etc/host-hooks"
if [ ! -e "$UBUNTU/etc/host-hooks/50-agents.hook" ] && \
   [ ! -e "$UBUNTU/etc/host-hooks/50-agents.hook.disabled" ]; then
    install -m 0755 "$AGENTS_HOOK" "$UBUNTU/etc/host-hooks/50-agents.hook.disabled"
fi

exec sh /data/data/com.termux/files/home/start_ubuntu.sh << 'CHROOT_CMD'
set -e

export DEBIAN_FRONTEND=noninteractive

apt-get update
apt-get install -y tmux curl ca-certificates gpg git

# tmux config is owned by ssh_setup.sh because that script runs at boot and
# needs to preserve default-shell, True Color, and mouse settings together.

# uv installed per-user into ~/.local/bin. Keeps Python dependency graphs out
# of /usr and matches the global "uv everywhere, never pip" preference.
# Ubuntu's default ~/.profile already prepends ~/.local/bin to PATH when that
# dir exists at login time, so no ~/.profile edit needed here — but we create
# the dir up-front to guarantee the login-shell PATH picks it up on the first
# ssh session after install.
#
# Node comes from pnpm, also per-user: pnpm is the box's only JS package
# manager and it provisions Node itself, so there is no apt/NodeSource Node
# (which root would see, and agents would not). Pinned to major 24, the
# version OpenClaw's docs recommend. The skip test runs as `user` — a root-side
# `command -v node` can't see the pnpm shim and would reinstall every run.
su -l user -s /bin/sh <<'USER_CMD'
set -e
mkdir -p "$HOME/.local/bin"
if ! command -v uv >/dev/null 2>&1; then
    curl -LsSf https://astral.sh/uv/install.sh | sh
fi

export PNPM_HOME="$HOME/.local/share/pnpm"
export PATH="$PNPM_HOME/bin:$PNPM_HOME:$PATH"
if ! command -v pnpm >/dev/null 2>&1; then
    # `pnpm setup` (run by the installer) edits the rc file of $SHELL; give it
    # the login shell, not the /bin/sh this block runs under.
    curl -fsSL https://get.pnpm.io/install.sh \
        | SHELL="$(getent passwd "$(id -un)" | cut -d: -f7)" sh -
fi
if ! node -v 2>/dev/null | grep -qE '^v(2[4-9]|[3-9][0-9])\.'; then
    pnpm runtime set node 24 -g
fi
USER_CMD

echo --- versions ---
tmux -V
su -l user -s /bin/sh -c 'PATH="$HOME/.local/share/pnpm/bin:$HOME/.local/bin:$PATH"; node --version; pnpm --version; uv --version'
echo --- helpers ---
ls -l /usr/local/bin/tmux-service /usr/local/sbin/run-as   # run-as from ssh_setup.sh
CHROOT_CMD
