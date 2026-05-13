#!/system/bin/sh
exec sh /data/data/com.termux/files/home/start_ubuntu.sh << 'CHROOT_CMD'
set -e

# Identity + prefs (hostname, --ssh) persist in tailscaled.state, so a fresh
# tailscaled normally auto-reconnects without `tailscale up`. But it doesn't
# always: a logout-from-admin-console, a key expiry, or an internal flap
# leaves tailscaled running yet the node "Down" on the tailnet. Observed
# 2026-05-07 — `tailscale status` from Mac listed moon offline despite a
# healthy `ps` on device. Calling `tailscale up` post-launch forces the
# state machine to "Connected" and is a no-op when already connected, so it
# costs nothing on healthy boots and recovers the unhealthy ones.

mkdir -p /var/lib/tailscale /var/run/tailscale

# Kill any stale tailscaled (e.g. leftover from prior boot or hot restart)
pkill -f '/usr/sbin/tailscaled' 2>/dev/null || true
sleep 1

# Userspace networking: the chroot has no /dev/net/tun, so tailscaled does
# its own packet I/O. SOCKS5/HTTP proxies are disabled since we only need
# inbound SSH, not outbound routing through the tailnet.
nohup /usr/sbin/tailscaled \
    --tun=userspace-networking \
    --state=/var/lib/tailscale/tailscaled.state \
    --socket=/var/run/tailscale/tailscaled.sock \
    > /var/log/tailscaled.log 2>&1 &

# Wait for tailscaled to bind its socket before driving it.
sleep 3

# Re-apply prefs and force the link up. Flags must match the original
# interactive `tailscale up` (see docs/04-tailscale.md) — modern Tailscale
# requires every preference to be specified on each `up`, otherwise it
# rejects the call. No --force-reauth: tailscaled.state already holds a
# valid node key, so this is a silent no-op when keys are still good and
# only prints an auth URL on the rare case that the key has expired.
echo --- tailscale up ---
/usr/bin/tailscale --socket=/var/run/tailscale/tailscaled.sock up \
    --ssh \
    --hostname=moon 2>&1 | head -20 || echo "(tailscale up failed)"

# Verify
echo --- tailscaled process ---
ps -eo pid,user,cmd | grep -E 'tailscaled( |$)' | grep -v grep || echo "(tailscaled not running)"
echo --- tailscale status ---
/usr/bin/tailscale --socket=/var/run/tailscale/tailscaled.sock status 2>&1 | head -20 || echo "(tailscale status failed)"
CHROOT_CMD
