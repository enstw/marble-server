#!/system/bin/sh
# thermal_setup.sh — deploy the CPU max-freq cap + passive thermal monitor and run
# them now (and at every boot, via service.sh). Invoke from Android:
#   adb shell su -c 'sh /data/data/com.termux/files/home/thermal_setup.sh'
#
# Sources of truth in the repo (push these to Termux home first, alongside this script):
#   scripts/host-hooks/60-thermal.hook  -> /etc/host-hooks/60-thermal.hook  (boot hook)
#   scripts/moon-thermal-monitor.sh     -> /usr/local/sbin/moon-thermal-monitor (logger)
#   config/moon-thermal.conf            -> /etc/moon-thermal.conf  (cap freqs + monitor settings)
# This script just installs them into the chroot and runs the hook once, so
# provisioning and boot apply the cap + start the monitor identically.
set -e

HOME_T=/data/data/com.termux/files/home
UBUNTU=$HOME_T/ubuntu
HOOK_SRC=$HOME_T/60-thermal.hook
MON_SRC=$HOME_T/moon-thermal-monitor.sh
CONF_SRC=$HOME_T/moon-thermal.conf

for f in "$HOOK_SRC" "$MON_SRC" "$CONF_SRC"; do
    [ -r "$f" ] || { echo "ERROR: $f missing — push it to Termux home first" >&2; exit 1; }
done

# Boot hook + monitor binary: overwrite (repo is the source of truth).
install -d -m 0755 "$UBUNTU/etc/host-hooks"
install -m 0755 "$HOOK_SRC" "$UBUNTU/etc/host-hooks/60-thermal.hook"
install -d -m 0755 "$UBUNTU/usr/local/sbin"
install -m 0755 "$MON_SRC" "$UBUNTU/usr/local/sbin/moon-thermal-monitor"

# Config: install only if absent, so on-device cap tuning isn't clobbered by a re-run.
if [ ! -f "$UBUNTU/etc/moon-thermal.conf" ]; then
    install -m 0644 "$CONF_SRC" "$UBUNTU/etc/moon-thermal.conf"
    echo "installed /etc/moon-thermal.conf"
else
    echo "kept existing /etc/moon-thermal.conf (edit it to retune; not overwritten)"
fi

# Enter the chroot and run the hook we just deployed (applies cap + starts monitor now).
exec sh "$HOME_T/start_ubuntu.sh" << 'CHROOT_CMD'
exec /etc/host-hooks/60-thermal.hook   # exec directly so the hook honors its own shebang, as service.sh does
CHROOT_CMD
