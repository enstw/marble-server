#!/bin/sh
# android-unlock — wake the screen and dismiss the keyguard.
#
# Android drops the CPU into a lower-power state when the screen is off,
# and Doze policy nibbles further at throughput for background workloads.
# Even with the lockscreen disabled (the standing policy on this device
# so CE storage auto-unlocks at boot — see docs/01-lineage-ksu.md), the
# screen-off power state is measurable at the Ubuntu workload layer. This
# script is the manual override for when you need governors pinned back
# to performance.
#
# Self-handles the chroot escape — see android-lock.sh for the rationale.
#
# Deployment: ssh_setup.sh installs this at /usr/local/sbin/android-unlock
# (root-only, since chroot needs CAP_SYS_CHROOT), with a NOPASSWD sudoers
# entry in /etc/sudoers.d/50-moon-helpers and a wrapper at /usr/local/bin/android-unlock
# so callers can just type `android-unlock` from PATH.
#
# Usage:
#   android-unlock [--stayon]                              # from user ssh (via PATH wrapper)
#   sudo /usr/local/sbin/android-unlock [--stayon]         # from inside the chroot as user
#   ssh moon-user android-unlock                           # from a workstation
#
# Flags:
#   --stayon   Also set `svc power stayon true` so the display stays on
#              while any power source is attached. Persistent until
#              explicitly cleared with `svc power stayon false`.

STAYON=0
for arg in "$@"; do
    case "$arg" in
        --stayon) STAYON=1 ;;
        *) echo "android-unlock: unknown arg: $arg" >&2; exit 2 ;;
    esac
done

# KEYCODE_WAKEUP = 224. Safe to call when already awake — no-op.
# wm dismiss-keyguard: no-op when lockscreen is disabled; meaningful
# if a PIN/pattern ever gets re-enabled on the device.
CMDS='input keyevent 224; wm dismiss-keyguard'
[ "$STAYON" = 1 ] && CMDS="$CMDS; svc power stayon true"

exec chroot /proc/1/root /system/bin/sh -c "$CMDS"
