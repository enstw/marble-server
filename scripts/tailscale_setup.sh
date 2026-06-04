#!/system/bin/sh
# tailscale_setup.sh — deploy the 20-tailscale.hook boot hook and run it once
# so tailscaled comes up now (and at every boot, via service.sh). Invoke from
# Android: adb shell su -c 'sh /data/data/com.termux/files/home/tailscale_setup.sh'
#
# The hook (scripts/host-hooks/20-tailscale.hook) is the single source of truth
# for *how* to start tailscaled — this script just deploys it and runs it, so
# provisioning and boot bring tailscaled up identically.
set -e

UBUNTU=/data/data/com.termux/files/home/ubuntu
TS_HOOK=/data/data/com.termux/files/home/20-tailscale.hook

# Deploy the boot hook into the chroot, so a rebuild that rm's the rootfs gets
# the hook redeposited by re-running this script. service.sh runs every
# /etc/host-hooks/*.hook at boot.
if [ ! -r "$TS_HOOK" ]; then
    echo "ERROR: $TS_HOOK missing — push scripts/host-hooks/20-tailscale.hook first" >&2
    exit 1
fi
install -d -m 0755 "$UBUNTU/etc/host-hooks"
install -m 0755 "$TS_HOOK" "$UBUNTU/etc/host-hooks/20-tailscale.hook"

# Enter the chroot and run the hook we just deployed.
exec sh /data/data/com.termux/files/home/start_ubuntu.sh << 'CHROOT_CMD'
exec sh /etc/host-hooks/20-tailscale.hook
CHROOT_CMD
