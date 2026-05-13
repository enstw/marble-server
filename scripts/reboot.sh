#!/bin/sh
# /usr/local/sbin/reboot — explicit disconnect-then-reboot for `moon`.
#
# Schedules the Android-side reboot in a detached background process, then
# SIGHUPs the per-session sshd so the ssh client returns on a clean
# session-closed. Replaces (and shadows) Ubuntu's systemd-wrapper /sbin/reboot
# — in-chroot reboot(2) hangs ssh because the kernel panics before sshd can
# close the TCP socket. PATH-first in interactive shells, in `sudo`'s
# secure_path. The non-root `user` normally reaches it through the
# /usr/local/bin/reboot wrapper installed by ssh_setup.sh.
#
# Deployment: ssh_setup.sh installs this at /usr/local/sbin/reboot with mode
# 0755, NOPASSWD sudoers in /etc/sudoers.d/50-moon-helpers, and a wrapper at
# /usr/local/bin/reboot so `user` can call it from any shell.
#
# Installed target runs as root. Invocations:
#   reboot                          # in-chroot user shell (PATH wrapper → sudo)
#   sudo reboot                     # ditto, explicit
#   ssh moon reboot                 # as user from a workstation (NOPASSWD)
#   ssh moon-user reboot            # as user from a workstation (NOPASSWD)

set -e

# Step 1: schedule the Android-side reboot, fully detached. nohup + &
# survives this script's exit and the subsequent sshd HUP. 2 s sleep
# gives in-flight writes time to drain before the kernel goes down.
# `chroot /proc/1/root` escapes the Ubuntu chroot back to Android root
# so we can reach /system/bin/reboot.
nohup chroot /proc/1/root /system/bin/sh -c \
    '(sleep 2; /system/bin/reboot) </dev/null >/dev/null 2>&1 &' \
    </dev/null >/dev/null 2>&1 &

# Step 2: walk up two hops ($$ → login shell → per-session sshd) and
# SIGHUP the sshd. OpenSSH responds by closing the channel and FIN-ing
# the TCP socket — the client returns within tens of ms instead of
# waiting on FIN flush after EOF. Best-effort: if the chain breaks
# (e.g. invoked from a console rather than ssh), the reboot is already
# scheduled, so silent failure is fine.
ssh_pid=$(awk '{print $4}' /proc/$PPID/stat 2>/dev/null || true)
if [ -n "$ssh_pid" ] && [ "$ssh_pid" != "1" ]; then
    kill -HUP "$ssh_pid" 2>/dev/null || true
fi

exit 0
