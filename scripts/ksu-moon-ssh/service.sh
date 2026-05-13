#!/system/bin/sh
# moon-ssh: run at KSU late_start service — enter Ubuntu chroot, start sshd.
#
# Depends on: /data/data/com.termux/files/home/{start_ubuntu.sh,ssh_setup.sh}
# and the extracted Ubuntu rootfs at /data/data/com.termux/files/home/ubuntu.
# Relies on the screen lock being disabled so CE storage auto-unlocks at boot
# and /data/data/com.termux/ is reachable here (service.d timing is before
# any user interaction).

# Two-stage logging.
#
# Stage 1 ($PRELOG, on /data DE storage) is always available at late_start, so
# the polling preamble is recorded even if the chroot rootfs never comes up.
# Stage 2 ($LOG, inside the chroot rootfs) starts once the chroot path is
# verified — same architectural payoff as host-hooks/: `cat /var/log/moon-
# ssh-boot.log` from inside the chroot reads the boot record, no adb hop.
#
# History: 2026-05-07 (commit f7edfd1) initially `exec >`'d straight to $LOG.
# At late_start, /data/data/com.termux/... can lag behind /data — the CE-
# storage app-data subtree finishes populating after late_start fires. exec(2)
# to a path whose parent doesn't yet exist makes mksh abort the script
# silently — no log, no sshd, no tailscaled. The ten-second poll below was
# already there to bridge that window; it just has to run before the
# in-chroot redirect, not after.
PRELOG=/data/local/tmp/moon-ssh-boot.log
LOG=/data/data/com.termux/files/home/ubuntu/var/log/moon-ssh-boot.log

exec > "$PRELOG" 2>&1

echo "=== moon-ssh service.sh invoked at $(date) (PID $$) ==="
echo "uid=$(id -u) gid=$(id -g) context=$(cat /proc/self/attr/current 2>/dev/null)"

# Kernel hostname — Android init sets it to "localhost" by default. The chroot
# shares the host UTS namespace, so this single call renames the Android shell
# prompt, `uname -n`, and the chroot's `hostname` output in one shot. Ubuntu's
# /etc/hostname inside the chroot is a separate file read by login shells — set
# that too (start_ubuntu.sh writes it on every chroot entry, but set here for
# any direct-chroot paths).
hostname moon

# Defensive poll: even with CE auto-unlock, there is a brief window post-
# /data-mount where app data directories are still being populated by init.
# Ten seconds is far longer than observed boot windows and still bounds the
# module against a truly broken state.
for i in 1 2 3 4 5 6 7 8 9 10; do
    [ -d /data/data/com.termux/files/home ] && break
    echo "[$i] waiting for /data/data/com.termux/files/home..."
    sleep 1
done

if [ ! -d /data/data/com.termux/files/home ]; then
    echo "ERROR: /data/data/com.termux/files/home never appeared (preserved at $PRELOG)"
    exit 1
fi

# Stage 2 switch — fold the preamble into the in-chroot log and re-redirect.
# `cp` then `exec >>` (append) preserves the polling preamble; the previous
# boot's $LOG is overwritten by `cp`, matching $PRELOG's overwrite behavior.
mkdir -p "$(dirname "$LOG")"
cp "$PRELOG" "$LOG"
exec >> "$LOG" 2>&1
echo "=== moon-ssh: switched log from $PRELOG to $LOG at $(date) ==="

# ssh_setup.sh internally execs start_ubuntu.sh with a heredoc payload that
# configures sshd and launches it. Each *_setup.sh is its own chroot session
# (exec replaces the shell, and when the heredoc ends the chroot exits),
# so tailscale_setup.sh runs as a separate invocation afterwards. Both
# daemons (sshd, tailscaled) are nohup/background inside their heredoc so
# they survive the chroot exit.
sh /data/data/com.termux/files/home/ssh_setup.sh
rc_ssh=$?
echo "=== ssh_setup.sh exited rc=$rc_ssh at $(date) ==="

sh /data/data/com.termux/files/home/tailscale_setup.sh
rc_ts=$?
echo "=== tailscale_setup.sh exited rc=$rc_ts at $(date) ==="

# Gated AI-agent launch. Noop by default — the operator opts in by touching
# agents.enabled once they have agents configured in agents_start.sh. Keeps
# boot quiet during setup iteration and gives a dead-simple kill switch
# (`rm agents.enabled`) that doesn't require editing the KSU module.
#
# Hook files live inside the chroot rootfs at /etc/host-hooks/ so they can
# be managed in-chroot with plain `sudo cp` — no chroot-escape gymnastics.
# We reach them from Android via the chroot's on-disk path. See
# docs/05-agents.md §3 for the rationale.
HOST_HOOKS=/data/data/com.termux/files/home/ubuntu/etc/host-hooks
rc_ag=0
if [ -e "$HOST_HOOKS/agents.enabled" ]; then
    sh "$HOST_HOOKS/agents_start.sh"
    rc_ag=$?
    echo "=== agents_start.sh exited rc=$rc_ag at $(date) ==="
else
    echo "=== agents_start skipped (agents.enabled absent) ==="
fi

# Surface whichever failed; sshd being up is more critical, so its rc wins.
# Agents failing to boot shouldn't mask an ssh/tailscale regression, so they
# come last in the precedence chain.
if [ "$rc_ssh" -ne 0 ]; then
    exit $rc_ssh
fi
if [ "$rc_ts" -ne 0 ]; then
    exit $rc_ts
fi
exit $rc_ag
