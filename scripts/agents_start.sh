#!/system/bin/sh
# agents_start.sh — boot-time launch for AI agents inside the chroot.
#
# Lives at /etc/host-hooks/agents_start.sh inside the chroot (Android-side
# path: $UBUNTU/etc/host-hooks/agents_start.sh). Invoked by
# scripts/ksu-moon-ssh/service.sh at late_start service, but only when
# /etc/host-hooks/agents.enabled exists. Touch that file once you have at
# least one agent configured below; rm it to silence boot-time launching
# without uninstalling anything.
#
# Shebang stays /system/bin/sh: this script is invoked from Android context
# (service.sh runs Android-side) and itself execs start_ubuntu.sh to enter
# the chroot. The file just happens to live in the chroot's filesystem so
# you can edit it in-chroot with `sudo` instead of bouncing through adb.
#
# Each agent is one line invoking tmux-service as the owning user. Examples:
#
#   su -l user -s /bin/sh -c 'tmux-service openclaw -- openclaw gateway --port 18789'
#   su -l user -s /bin/sh -c 'tmux-service hermes   -- hermes gateway start'
#
# Logs land in /home/user/.local/state/moon-agents/<name>.log. Attach from
# ssh with:  ssh moon-user -t tmux attach -t <name>

exec sh /data/data/com.termux/files/home/start_ubuntu.sh << 'CHROOT_CMD'
set -e

# FreelOAder — local OpenAI-compatible proxy in front of claude/codex/gemini
# CLIs (~/.hermes/config.yaml points at http://127.0.0.1:8000/v1). Must come
# up before hermes so hermes' first turn finds the gateway listening; hermes
# tolerates initial connect retries but skipping the race is cheaper than
# debugging a "model unavailable" at boot.
su -l user -s /bin/sh -c 'tmux-service freeloader -- sh -c "cd /home/user/freeloader && exec .venv/bin/uvicorn freeloader.frontend.app:create_app --factory --host 127.0.0.1 --port 8000"'

# Hermes Agent gateway — migrated 2026-05-07 from the systemd-user unit
# Hermes ships (`hermes gateway install` writes ~/.config/systemd/user/
# hermes-gateway.service). That unit is dead in this chroot — there's no
# PID 1 / systemd-user, by design (see docs/DESIGN.md). We use Hermes's
# foreground `gateway run` mode instead, the path the Hermes docs flag as
# "recommended for WSL, Docker, Termux" — i.e. exactly the no-init path
# this chroot is on. tmux-service supplies the missing pieces (named
# session for attach, while-true crash loop, log tee).
#
# --replace cleans up any lingering hermes process from a prior boot
# before the new instance binds the gateway socket.
su -l user -s /bin/sh -c 'tmux-service hermes -- hermes gateway run --replace'
CHROOT_CMD
