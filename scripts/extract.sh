#!/system/bin/sh
set -e
mkdir -p /data/data/com.termux/files/home/ubuntu
cd /data/data/com.termux/files/home/ubuntu
tar --numeric-owner -xpzf /sdcard/Download/ubuntu-base-26.04-beta-base-arm64.tar.gz
echo "=== top-level ==="
ls -la
echo "=== usr/bin count ==="
ls usr/bin/ | wc -l
echo "=== du -sh . ==="
du -sh .
