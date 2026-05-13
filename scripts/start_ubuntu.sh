#!/system/bin/sh
# start_ubuntu.sh — enter the Ubuntu 26.04 chroot on /data/data/com.termux/files/home/ubuntu
# Usage:
#   su -c /data/data/com.termux/files/home/start_ubuntu.sh              # interactive login shell
#   su -c '/data/data/com.termux/files/home/start_ubuntu.sh CMD ARGS'   # run one command

set -e

UBUNTU=/data/data/com.termux/files/home/ubuntu

is_mounted() { grep -q " $1 " /proc/mounts 2>/dev/null; }

bind_once() {
    src=$1; dst=$2; flag=${3:---bind}
    [ -d "$dst" ] || mkdir -p "$dst"
    is_mounted "$dst" && return 0
    mount $flag "$src" "$dst"
}

# Android mounts /data with nosuid,nodev (security baseline), disabling setuid
# binaries (sudo, su, ping) inside the chroot. Bind-mount $UBUNTU onto itself,
# then remount the bind with suid,exec,dev so the kernel honors setuid bits.
# Flag changes on a bind-remount affect only the bind — they don't propagate
# through /data's shared subtree. Confirmed live 2026-04-21 on kernel
# 5.10.252: nosuid on /data was what broke Ubuntu 26.04's sudo-rs at
# /usr/lib/cargo/bin/sudo (setuid bit was correctly set; kernel refused to
# honor it until the chroot root was bind-remounted with suid).
if ! is_mounted "$UBUNTU"; then
    mount --bind "$UBUNTU" "$UBUNTU"
fi
mount -o remount,bind,suid,exec,dev "$UBUNTU"

# Narrow /dev binds — never --rbind /dev. An rbind replicates nested kernel
# filesystems (binderfs, kgsl, etc.) into the chroot. On 2026-04-20 a lazy
# umount against the rbind'd /dev wiped the host's binderfs mount via mount
# propagation, killing every Android app until reboot.
#
# Structural defense (rslave on the chroot subtree) would be cleaner, but
# Android's toybox mount has no --make-rslave. Narrow binds alone address
# the root cause: leaf-node binds have no nested structure to replicate, so
# umount churn against them cannot propagate binderfs-style. Just mount only
# the device nodes Ubuntu userspace actually needs.
if ! is_mounted "$UBUNTU/dev"; then
    mount -t tmpfs -o mode=755,nosuid tmpfs "$UBUNTU/dev"
fi
mkdir -p "$UBUNTU/dev/pts" "$UBUNTU/dev/shm"
is_mounted "$UBUNTU/dev/pts" || \
    mount -t devpts -o newinstance,ptmxmode=0666,mode=0620 devpts "$UBUNTU/dev/pts"
is_mounted "$UBUNTU/dev/shm" || \
    mount -t tmpfs -o mode=1777,nosuid,nodev tmpfs "$UBUNTU/dev/shm"
# mknod rather than bind-mount: toybox mount auto-detects "char device on
# regular file" as a loopback mount and fails in losetup. mknod'ing with
# the same major/minor gives an identical node without going through
# mount(2) at all.
for node in null:1:3 zero:1:5 full:1:7 random:1:8 urandom:1:9 tty:5:0; do
    name=${node%%:*}; rest=${node#*:}; major=${rest%:*}; minor=${rest#*:}
    # Check -c (char device), not -e (any existence). A stray regular file
    # at /dev/null — e.g. from an earlier bind-mount attempt — looks like
    # it "exists" but traps writes at tmpfs size limits instead of discarding.
    [ -c "$UBUNTU/dev/$name" ] && continue
    rm -f "$UBUNTU/dev/$name"
    mknod -m 666 "$UBUNTU/dev/$name" c "$major" "$minor"
done
# ptmx — point at the devpts instance we just mounted
[ -e "$UBUNTU/dev/ptmx" ] || ln -s pts/ptmx "$UBUNTU/dev/ptmx"

bind_once /proc   "$UBUNTU/proc"   --rbind
bind_once /sys    "$UBUNTU/sys"    --rbind
bind_once /sdcard "$UBUNTU/sdcard"

is_mounted "$UBUNTU/tmp" || mount -t tmpfs tmpfs "$UBUNTU/tmp"

# DNS — chroot has no access to the host /etc/resolv.conf.
# Remove first: apt install of systemd-resolved replaces resolv.conf with a
# symlink to /run/systemd/resolve/stub-resolv.conf, whose target doesn't exist
# because we never run systemd. Without rm, `cat >` would follow the dangling
# symlink and fail.
rm -f "$UBUNTU/etc/resolv.conf"
cat > "$UBUNTU/etc/resolv.conf" <<EOF
nameserver 1.1.1.1
nameserver 8.8.8.8
EOF

# Minimal hosts file (overwrite Ubuntu's placeholder)
cat > "$UBUNTU/etc/hosts" <<EOF
127.0.0.1   localhost moon
::1         localhost moon
EOF
echo moon > "$UBUNTU/etc/hostname"

CHROOT_ENV="HOME=/root TERM=${TERM:-xterm-256color} LANG=C.UTF-8 PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

if [ $# -gt 0 ]; then
    exec chroot "$UBUNTU" /usr/bin/env -i $CHROOT_ENV /bin/bash -c "$*"
else
    exec chroot "$UBUNTU" /usr/bin/env -i $CHROOT_ENV /bin/bash --login
fi
