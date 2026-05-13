#!/system/bin/sh
exec sh /data/data/com.termux/files/home/start_ubuntu.sh << 'CHROOT_CMD'
set -e
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y openssh-server ca-certificates less vim-tiny iproute2 iputils-ping
echo --- installed versions ---
sshd -V 2>&1 | head -3 || /usr/sbin/sshd -V 2>&1 | head -3
which sshd
dpkg -l openssh-server | tail -1
CHROOT_CMD
