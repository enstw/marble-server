#!/system/bin/sh
# Lazy-unmount every mount under the three mirrored ubuntu paths
for p in /data/data/com.termux/files/home/ubuntu /data_mirror/data_ce/null/0/com.termux/files/home/ubuntu /data/user/0/com.termux/files/home/ubuntu; do
    grep " $p" /proc/mounts | awk '{print $2}' | sort -r | while read m; do
        umount -l "$m" 2>/dev/null
    done
done
echo "--- remaining mounts under ubuntu ---"
grep ubuntu /proc/mounts | wc -l
echo "--- ls target ---"
ls -ld /data/data/com.termux/files/home/ubuntu 2>&1
