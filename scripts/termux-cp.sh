#!/bin/sh
# termux-cp — copy a file from inside the Ubuntu chroot to Termux's $HOME.
#
# Termux's home (/data/data/com.termux/files/home) is NOT bind-mounted into
# the chroot — see scripts/start_ubuntu.sh, the bind set is deliberate. So
# delivering the *bootstrap* scripts (start_ubuntu.sh, ssh_setup.sh,
# tailscale_setup.sh, agents_setup.sh) into Termux home from a workstation
# normally means `adb push`. This script is the in-chroot alternative for
# when you're already on the device.
#
# Boot-time HOOKS (agents_start.sh, agents.enabled, …) do NOT need this
# anymore — they live at /etc/host-hooks/ inside the chroot and are
# managed with `sudo cp` directly. See docs/05-agents.md §3.
#
#   1. Stage the file on /sdcard (FUSE — writable from chroot).
#   2. chroot into PID 1's root (real Android FS — see android-lock.sh for
#      the rationale) and copy the staged file into Termux home.
#   3. Remove the /sdcard stage.
#
# Source mode is re-applied on the destination because /sdcard is FUSE and
# strips perms in transit.
#
# Usage (from inside the Ubuntu chroot, as root):
#   ./termux-cp.sh <src> [dest-filename]
#
# Examples:
#   ./termux-cp.sh ~/marble-server/scripts/start_ubuntu.sh
#   ./termux-cp.sh ~/marble-server/scripts/ssh_setup.sh

set -e

SRC=$1
[ -n "$SRC" ] || { echo "termux-cp: missing source path" >&2; exit 2; }
[ -f "$SRC" ] || { echo "termux-cp: $SRC: not a regular file" >&2; exit 2; }

DEST_NAME=${2:-$(basename "$SRC")}
STAGE=/sdcard/.termux-cp.$$
MODE=$(stat -c '%a' "$SRC")

cleanup() { rm -f "$STAGE" 2>/dev/null || :; }
trap cleanup EXIT INT TERM

cp "$SRC" "$STAGE"

# Pass STAGE / DEST_NAME / MODE as positional args so single-quotes or
# spaces in any of them can't break out of the inner sh -c.
chroot /proc/1/root /system/bin/sh -c '
    set -e
    cp "$1" "/data/data/com.termux/files/home/$2"
    chmod "$3" "/data/data/com.termux/files/home/$2"
' _ "$STAGE" "$DEST_NAME" "$MODE"

echo "termux-cp: $SRC -> /data/data/com.termux/files/home/$DEST_NAME (mode $MODE)"
