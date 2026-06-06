#!/bin/sh
# android — Android-side device controls callable from inside the Ubuntu chroot.
#
# Subcommands:
#   lock              put the device into screen-off / low-power state
#   unlock [--stayon] wake the screen and dismiss the keyguard
#
# Android binaries like `input` / `wm` / `svc` are dynamically linked against
# /system/bin/linker64 (absolute path) and won't exec from inside the Ubuntu
# chroot directly. Each subcommand chroots into PID 1's root for the duration
# of the call: PID 1 is Android's init, which lives outside our chroot, so
# /proc/1/root is the real Android filesystem. From Android directly the chroot
# is a no-op (init's root is already /), so a single code path covers both
# contexts.
#
# Why `unlock` matters as a power lever: Android drops the CPU into a
# lower-power state when the screen is off, and Doze policy nibbles further at
# throughput for background workloads. Even with the lockscreen disabled (the
# standing policy on this device so CE storage auto-unlocks at boot — see
# docs/INSTALLATION.md § "CE storage prerequisite"), the screen-off power state
# is measurable at the Ubuntu workload layer. `unlock` is the manual override
# for when you need governors pinned back to performance.
#
# Deployment: ssh_setup.sh installs this at /usr/local/sbin/android (root-only,
# since chroot needs CAP_SYS_CHROOT), with a NOPASSWD sudoers entry in
# /etc/sudoers.d/50-moon-helpers. The script self-elevates (re-exec via sudo
# when not root — see below), so a bare `android <cmd>` works from any shell
# without a separate PATH wrapper.
#
# Usage:
#   android lock                                # from user ssh (self-elevates)
#   android unlock [--stayon]
#   sudo android lock                           # explicit; also fine
#   ssh moon-user android unlock                # from a workstation
#   adb shell su -c 'sh /data/data/com.termux/files/home/android.sh lock'  # from Android directly

# Self-elevate. A PATH-resident `android` resolves to this sbin copy first
# (/usr/local/sbin precedes /usr/local/bin), so a separate /usr/local/bin
# wrapper would be permanently shadowed — a bare `android` would run here
# UNPRIVILEGED and the chroot escape below would fail with ENOENT under /proc's
# hidepid. Re-exec through sudo (NOPASSWD) when not already root, so bare /
# `sudo` / `ssh moon-user android …` all reach root here. From Android directly
# (adb shell su) id is already 0, so this is a no-op.
if [ "$(id -u)" -ne 0 ]; then
    exec sudo /usr/local/sbin/android "$@"
fi

usage() {
    cat >&2 <<'EOF'
usage: android <command> [args]

commands:
  lock              screen off / low-power (KEYCODE_SLEEP)
  unlock [--stayon] wake screen + dismiss keyguard; --stayon also keeps the
                    display on while powered (svc power stayon true), persistent
                    until cleared with `svc power stayon false`
EOF
    exit 2
}

cmd=${1:-}
[ "$#" -gt 0 ] && shift

case "$cmd" in
    lock)
        [ "$#" -eq 0 ] || { echo "android lock: unexpected arg: $1" >&2; exit 2; }
        # KEYCODE_SLEEP = 223. Unambiguous — always sleeps, no matter the
        # current screen state. Prefer over KEYCODE_POWER (26) which toggles.
        exec chroot /proc/1/root /system/bin/input keyevent 223
        ;;
    unlock)
        stayon=0
        for arg in "$@"; do
            case "$arg" in
                --stayon) stayon=1 ;;
                *) echo "android unlock: unknown arg: $arg" >&2; exit 2 ;;
            esac
        done
        # KEYCODE_WAKEUP = 224. Safe to call when already awake — no-op.
        # wm dismiss-keyguard: no-op when lockscreen is disabled; meaningful
        # if a PIN/pattern ever gets re-enabled on the device.
        cmds='input keyevent 224; wm dismiss-keyguard'
        [ "$stayon" = 1 ] && cmds="$cmds; svc power stayon true"
        exec chroot /proc/1/root /system/bin/sh -c "$cmds"
        ;;
    -h|--help|help)
        usage
        ;;
    *)
        [ -n "$cmd" ] && echo "android: unknown command: $cmd" >&2
        usage
        ;;
esac
