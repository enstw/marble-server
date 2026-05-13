#!/bin/sh
# android-lock — put the device into screen-off / low-power state.
#
# Android binaries like `input` are dynamically linked against
# /system/bin/linker64 (absolute path) and won't exec from inside the
# Ubuntu chroot directly. The script chroots into PID 1's root for the
# duration of the call: PID 1 is Android's init, which lives outside our
# chroot, so /proc/1/root is the real Android filesystem. From Android
# directly the chroot is a no-op (init's root is already /), so a single
# code path covers both contexts.
#
# Deployment: ssh_setup.sh installs this at /usr/local/sbin/android-lock
# (root-only, since chroot needs CAP_SYS_CHROOT), with a NOPASSWD sudoers
# entry in /etc/sudoers.d/50-moon-helpers and a wrapper at /usr/local/bin/android-lock
# so callers can just type `android-lock` from PATH.
#
# Usage:
#   android-lock                                          # from user ssh (via PATH wrapper)
#   sudo /usr/local/sbin/android-lock                      # from inside the chroot as user
#   ssh moon-user android-lock                             # from a workstation
#   adb shell su -c 'sh /data/data/com.termux/files/home/android-lock.sh'  # from Android directly

# KEYCODE_SLEEP = 223. Unambiguous — always sleeps, no matter the current
# screen state. Prefer over KEYCODE_POWER (26) which toggles.
exec chroot /proc/1/root /system/bin/input keyevent 223
