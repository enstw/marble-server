#!/bin/sh
# /usr/local/sbin/reboot — explicit disconnect-then-reboot for `moon`.
#
# Schedules the Android-side reboot in a detached background process, then
# SIGHUPs the per-session sshd so the ssh client returns on a clean
# session-closed. Replaces (and shadows) Ubuntu's systemd-wrapper /sbin/reboot
# — in-chroot reboot(2) hangs ssh because the kernel panics before sshd can
# close the TCP socket. PATH-first in interactive shells, in `sudo`'s
# secure_path. The script self-elevates (re-exec via sudo when not root — see
# below), so the non-root `user` can call it bare.
#
# Deployment: ssh_setup.sh installs this at /usr/local/sbin/reboot with mode
# 0755 and a NOPASSWD sudoers entry in /etc/sudoers.d/50-moon-helpers. No PATH
# wrapper — /usr/local/sbin precedes /usr/local/bin (and systemd's /sbin) in
# PATH, so a bare `reboot` resolves to this script and self-elevates.
#
# Installed target runs as root. Invocations:
#   reboot                          # in-chroot user shell (self-elevates via sudo)
#   sudo reboot                     # ditto, explicit
#   ssh moon reboot                 # as user from a workstation (NOPASSWD)
#   ssh moon-user reboot            # as user from a workstation (NOPASSWD)

set -e

# Disconnect the interactive client FIRST, while we still run as the
# unprivileged user with $TMUX in the environment (sudo's env_reset scrubs it
# past the self-elevation below). Every interactive login is wrapped in a
# per-session tmux (ssh_setup.sh §3/§6): the pane shell is a child of the tmux
# *server* — a detached daemon — so the per-session sshd is NOT in our process
# ancestry and the parent-walk in Step 2 can never reach it. Detaching the
# client makes `tmux attach` (hence the ssh session) return at once; the pane,
# and this script, keep running detached so the reboot scheduled below still
# fires. No-op for the non-interactive `ssh moon reboot` path ($TMUX unset) —
# the sshd HUP in Step 2 covers that one instead.
if [ -n "$TMUX" ] && command -v tmux >/dev/null 2>&1; then
    sess=$(tmux display-message -p '#{session_name}' 2>/dev/null || true)
    [ -n "$sess" ] && tmux detach-client -s "$sess" 2>/dev/null || true
fi

# Self-elevate — same pattern as android.sh. A bare `reboot` resolves here
# (/usr/local/sbin is PATH-first), so without this it would run UNPRIVILEGED
# and the chroot escape below would fail with ENOENT under /proc's hidepid.
# Re-exec through sudo (NOPASSWD) when not already root. No-op when already root
# (sudo reboot, or Android-side adb shell su).
if [ "$(id -u)" -ne 0 ]; then
    exec sudo /usr/local/sbin/reboot "$@"
fi

# Step 1: schedule the Android-side reboot, fully detached. nohup + &
# survives this script's exit and the subsequent sshd HUP. 2 s sleep
# gives in-flight writes time to drain before the kernel goes down.
# `chroot /proc/1/root` escapes the Ubuntu chroot back to Android root
# so we can reach /system/bin/reboot.
nohup chroot /proc/1/root /system/bin/sh -c \
    '(sleep 2; /system/bin/reboot) </dev/null >/dev/null 2>&1 &' \
    </dev/null >/dev/null 2>&1 &

# Step 2: SIGHUP the per-session sshd so a non-interactive `ssh moon reboot`
# returns at once instead of waiting on the TCP socket until the kernel panics.
# OpenSSH responds to the HUP by closing the channel and FIN-ing the socket.
# The ancestry here is  reboot.sh → sudo → login shell → sshd[-session]  — the
# sudo hop is the self-elevation above. A previous fixed two-hop walk pointed
# one short (at the login shell) once that hop was added, which is why reboot
# stopped disconnecting. Climb parents and HUP the first sshd instead of
# counting hops; OpenSSH ≥9.8 names the per-session process "sshd-session", so
# match on the "sshd" prefix. Best-effort: interactive logins (tmux — handled
# before the elevation above), console/adb, and Tailscale SSH (tailscaled, not
# sshd) have no sshd ancestor, so the loop simply finds nothing and the
# already-scheduled reboot proceeds.
pid=$PPID
while [ "${pid:-0}" -gt 1 ] 2>/dev/null; do
    read -r comm < "/proc/$pid/comm" 2>/dev/null || break
    case "$comm" in
        sshd|sshd-*) kill -HUP "$pid" 2>/dev/null || true; break ;;
    esac
    read -r _ rest < "/proc/$pid/stat" 2>/dev/null || break
    rest=${rest##*\) }   # drop "(comm) " → "state ppid …"
    rest=${rest#* }      # drop state    → "ppid …"
    pid=${rest%% *}      # ppid
done

exit 0
