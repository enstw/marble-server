#!/system/bin/sh
# moon-ssh: run at KSU late_start service — enter the Ubuntu chroot once and
# run the boot hooks.
#
# Hook model (one file, one hook). Hooks live inside the chroot rootfs at
# /etc/host-hooks/*.hook (Android-side path
# $UBUNTU/etc/host-hooks/) so they can be managed in-chroot with plain
# `sudo mv`/`sudo install` — no adb push, no chroot-escape, no /sdcard
# staging. This script enters the chroot ONCE (via start_ubuntu.sh) and runs
# every *.hook in lexical order as root inside it.
#
#   - One file per hook:   /etc/host-hooks/NN-<name>.hook  (NN orders them)
#   - Enable / disable:    rename to NN-<name>.hook.disabled and back — the
#                          glob below only matches *.hook (no sidecar files).
#   - Run as another user: from inside a hook, `run-as <user> -- <cmd>`
#                          (su -l <user> -s /bin/sh -c …; see scripts/run-as.sh).
#   - Start-only:          hooks launch already-provisioned services. After a
#                          rootfs rebuild or config change, re-run the relevant
#                          *_setup.sh provisioning script — boot does not
#                          re-provision.
#
# Core hooks shipped: 10-sshd, 20-tailscale (enabled), 50-agents (a template
# of commented agent examples, deployed disabled as 50-agents.hook.disabled).
# Sources: scripts/host-hooks/.
#
# Depends on: /data/data/com.termux/files/home/start_ubuntu.sh and the
# extracted Ubuntu rootfs at /data/data/com.termux/files/home/ubuntu. Relies
# on the screen lock being disabled so CE storage auto-unlocks at boot and
# /data/data/com.termux/ is reachable here (service.d timing is before any
# user interaction).

# Two-stage logging.
#
# Stage 1 ($PRELOG, on /data DE storage) is always available at late_start, so
# the polling preamble is recorded even if the chroot rootfs never comes up.
# Stage 2 ($LOG, inside the chroot rootfs) starts once the chroot path is
# verified — `cat /var/log/moon-ssh-boot.log` from inside the chroot reads the
# boot record, no adb hop.
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
# /etc/hostname inside the chroot is a separate file read by login shells;
# start_ubuntu.sh writes it on every chroot entry.
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

# Enter the chroot ONCE and run every enabled hook. start_ubuntu.sh sets up the
# mounts/binds (suid remount, narrow /dev, /proc, DNS, …) and execs into a
# login bash that reads this heredoc on stdin. The heredoc is quoted
# ('CHROOT_CMD') so the loop body is evaluated entirely in-chroot, not by this
# Android shell.
#
# Each hook runs in its own subshell so a `set -e` abort (or any failure) in
# one hook can't abort the loop — the rest still run. The first non-zero rc
# wins as our overall exit code; because hooks run in lexical order, the
# lowest-numbered failing hook (10-sshd before 20-tailscale before 50-agents)
# is the one surfaced, preserving "sshd regressions are never masked."
sh /data/data/com.termux/files/home/start_ubuntu.sh << 'CHROOT_CMD'
first_fail=0
ran=0
for h in /etc/host-hooks/*.hook; do
    [ -e "$h" ] || continue   # no-match guard: glob stays literal when empty
    ran=1
    name=$(basename "$h")
    echo "=== hook $name start $(date) ==="
    ( "$h" ); rc=$?   # run the file directly (hooks are 0755) so each honors its own shebang
    echo "=== hook $name exited rc=$rc at $(date) ==="
    if [ "$rc" -ne 0 ] && [ "$first_fail" -eq 0 ]; then
        first_fail=$rc
    fi
done
[ "$ran" -eq 0 ] && echo "=== no hooks in /etc/host-hooks (nothing to run) ==="
exit $first_fail
CHROOT_CMD
rc=$?

echo "=== moon-ssh: hooks finished rc=$rc at $(date) ==="
exit $rc
