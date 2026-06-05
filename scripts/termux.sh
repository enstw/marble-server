#!/bin/sh
# termux — in-chroot bridge to Termux $HOME and Android (init) context.
#
# Subcommands:
#   cp <src> [dest-name]    copy a file from the chroot into Termux $HOME
#   rm <name>...            remove file(s) from Termux $HOME
#   exec <cmd> [args...]    run a command in Android (init) context
#
# All three escape the Ubuntu chroot the same way: chroot into PID 1's root.
# PID 1 is Android's init, which lives OUTSIDE our chroot, so /proc/1/root is
# the real Android filesystem (see scripts/android.sh for the full rationale).
# From Android directly the chroot is a no-op (init's root is already /), so one
# code path covers both contexts. All three need root (CAP_SYS_CHROOT) — invoke
# with sudo from inside the chroot.
#
# Why this exists: Termux's home (/data/data/com.termux/files/home) is NOT
# bind-mounted into the chroot (see scripts/start_ubuntu.sh — the bind set is
# deliberate). Delivering the bootstrap scripts (start_ubuntu.sh, ssh_setup.sh,
# tailscale_setup.sh, agents_setup.sh) into Termux home, dropping stale copies,
# and running them in Android context normally means `adb push` + `adb shell
# su -c …` from a workstation. This is the in-chroot alternative for when you
# are already on the device (e.g. over tailnet SSH, no adb).
#
# NOT installed and deliberately NOT NOPASSWD: this is a repo-local helper run
# in place (sudo ./scripts/termux.sh …). `exec` runs arbitrary commands as root
# in Android context, so it must never be passwordless. Contrast the installed
# `reboot` / `android` helpers, which ARE NOPASSWD for `user` precisely because
# each is a narrow, fixed action behind an explicit-path sudoers stanza — a
# generic exec cannot share that boundary. See docs/MAINTENANCE.md §1.
#
# Usage (from inside the Ubuntu chroot, as root):
#   sudo ./termux.sh cp scripts/ssh_setup.sh
#   sudo ./termux.sh rm android-lock.sh android-unlock.sh
#   sudo ./termux.sh exec sh /data/data/com.termux/files/home/ssh_setup.sh

set -e

TERMUX_HOME=/data/data/com.termux/files/home

usage() {
    echo "usage: termux.sh {cp <src> [dest-name] | rm <name>... | exec <cmd> [args...]}" >&2
    exit 2
}

# PATH for the escaped Android shell. The chroot inherits the chroot's own PATH
# (/usr/local/sbin:…:/bin), which names paths that don't exist on the Android
# side — bare `cp`/`rm`/`sh` would not resolve. Pin Android's toybox locations
# so a `termux exec sh …` resolves the same as an adb/su launch would.
ANDROID_PATH=/system/bin:/system/xbin

cmd=${1:-}
[ -n "$cmd" ] || usage
shift || true

case "$cmd" in
cp)
    SRC=${1:-}
    [ -n "$SRC" ] || { echo "termux cp: missing source path" >&2; exit 2; }
    [ -f "$SRC" ] || { echo "termux cp: $SRC: not a regular file" >&2; exit 2; }
    DEST_NAME=${2:-$(basename "$SRC")}
    case "$DEST_NAME" in
        */*) echo "termux cp: $DEST_NAME: dest must be a bare filename in Termux home" >&2; exit 2 ;;
    esac
    STAGE=/sdcard/.termux-stage.$$
    MODE=$(stat -c '%a' "$SRC")

    cleanup() { rm -f "$STAGE" 2>/dev/null || :; }
    trap cleanup EXIT INT TERM

    # Stage on /sdcard (FUSE — writable from the chroot), then escape to Android
    # to land it in Termux home. /sdcard is FUSE and strips perms in transit, so
    # re-apply the source mode on the destination. Pass STAGE/DEST/MODE as
    # positional args so spaces or quotes in any of them can't break the inner sh.
    cp "$SRC" "$STAGE"
    chroot /proc/1/root /system/bin/sh -c '
        export PATH=/system/bin:/system/xbin
        set -e
        cp "$1" "/data/data/com.termux/files/home/$2"
        chmod "$3" "/data/data/com.termux/files/home/$2"
    ' _ "$STAGE" "$DEST_NAME" "$MODE"

    echo "termux cp: $SRC -> $TERMUX_HOME/$DEST_NAME (mode $MODE)"
    ;;
rm)
    [ -n "${1:-}" ] || { echo "termux rm: missing file name" >&2; exit 2; }
    # Names are bare basenames in Termux home — reject any path component so a
    # stray '../' or absolute path can't reach outside it. Pass as positional
    # args to the escaped shell (no quote-breakout); prefix the home dir inside.
    for name in "$@"; do
        case "$name" in
            */*) echo "termux rm: $name: must be a bare filename in Termux home" >&2; exit 2 ;;
        esac
    done
    chroot /proc/1/root /system/bin/sh -c '
        export PATH=/system/bin:/system/xbin
        set -e
        for n; do rm -f "/data/data/com.termux/files/home/$n"; done
    ' _ "$@"
    echo "termux rm: removed $* from $TERMUX_HOME"
    ;;
exec)
    [ -n "${1:-}" ] || { echo "termux exec: missing command" >&2; exit 2; }
    # Run a command in Android (init) context. exec-into the escaped shell so
    # the caller gets the command's real exit status. Args are positional —
    # no quote-breakout. PATH pinned Android-side (see ANDROID_PATH note above).
    exec chroot /proc/1/root /system/bin/sh -c "export PATH=$ANDROID_PATH; "'exec "$@"' _ "$@"
    ;;
*)
    usage
    ;;
esac
