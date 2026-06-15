#!/bin/sh
# moon-thermal-monitor — passive thermal + cpufreq logger for the moon server.
#
# EVIDENCE ONLY. It samples /sys and appends a line to a log; it NEVER writes a
# control node. So it cannot fight the vendor thermal daemon (mi_thermald) and has
# nothing to oscillate — unlike a reactive throttler. Its job is to give us the
# peak-temperature data needed to choose the proper CPU cap, and to leave a record
# so the next thermal incident has evidence instead of a bare `reboot` boot tag.
#
# Deployed to /usr/local/sbin/moon-thermal-monitor and launched detached by
# /etc/host-hooks/60-thermal.hook at boot. Source of truth: scripts/moon-thermal-monitor.sh.
#
# Each sample line:
#   <iso8601> cpu=<max cpu-1-* °C> chg=<charger_therm0 °C> bat=<battery °C> \
#     p4cur=<kHz> p4max=<kHz> p7cur=<kHz> p7max=<kHz> load=<1m>
# Logging p4max/p7max every sample doubles as the cap STICKINESS check: if the vendor
# stack ever rewrites scaling_max_freq back to cpuinfo_max, it shows up right here.
#
# Stop:  pkill -f /usr/local/sbin/moon-thermal-monitor
# Tune:  /etc/moon-thermal.conf  (MON_INTERVAL / MON_LOG / MON_LOG_MAX_BYTES / MON_LOG_KEEP)
#
# No `set -e`: a transient sysfs read hiccup must never kill the logger. Every read
# is guarded so one bad sample degrades to "?" rather than exiting the loop.

CONF=/etc/moon-thermal.conf
[ -r "$CONF" ] && . "$CONF"
MON_INTERVAL=${MON_INTERVAL:-30}
MON_LOG=${MON_LOG:-/var/log/moon-thermal.log}
MON_LOG_MAX_BYTES=${MON_LOG_MAX_BYTES:-2097152}
MON_LOG_KEEP=${MON_LOG_KEEP:-4000}

THERMAL=/sys/class/thermal
CPUFREQ=/sys/devices/system/cpu/cpufreq

# Resolve thermal zones by TYPE name once. Zone *numbers* are not stable across
# kernels/boots (but are stable within a boot), so match on the type string.
CPU_TEMPS=""
CHG_TEMP=""
BAT_TEMP=""
for z in "$THERMAL"/thermal_zone*; do
    t=$(cat "$z/type" 2>/dev/null) || continue
    case "$t" in
        cpu-1-*)        CPU_TEMPS="$CPU_TEMPS $z/temp" ;;
        charger_therm0) CHG_TEMP="$z/temp" ;;
        battery)        BAT_TEMP="$z/temp" ;;
    esac
done

# millidegrees -> "NN.N" (integer-only; no float in POSIX sh)
mc_to_c() {
    [ -n "$1" ] || { echo "?"; return; }
    echo "$(( $1 / 1000 )).$(( ($1 % 1000) / 100 ))"
}

read_max() {  # max over the millidegree temp paths in $1
    m=-1
    for f in $1; do
        v=$(cat "$f" 2>/dev/null) || continue
        [ "$v" -gt "$m" ] 2>/dev/null && m=$v
    done
    [ "$m" -ge 0 ] && echo "$m" || echo ""
}

freq() { cat "$CPUFREQ/$1/$2" 2>/dev/null || echo "?"; }

trim_log() {
    sz=$(wc -c < "$MON_LOG" 2>/dev/null || echo 0)
    if [ "$sz" -gt "$MON_LOG_MAX_BYTES" ] 2>/dev/null; then
        tail -n "$MON_LOG_KEEP" "$MON_LOG" > "$MON_LOG.tmp" 2>/dev/null && mv "$MON_LOG.tmp" "$MON_LOG"
    fi
}

mkdir -p "$(dirname "$MON_LOG")" 2>/dev/null
echo "=== moon-thermal-monitor start $(date -Is) interval=${MON_INTERVAL}s cpu_zones=[$CPU_TEMPS] ===" >> "$MON_LOG"

while true; do
    cpu=$(mc_to_c "$(read_max "$CPU_TEMPS")")
    chg=$(mc_to_c "$(cat "$CHG_TEMP" 2>/dev/null)")
    bat=$(mc_to_c "$(cat "$BAT_TEMP" 2>/dev/null)")
    load=$(cut -d' ' -f1 /proc/loadavg 2>/dev/null || echo "?")
    printf '%s cpu=%s chg=%s bat=%s p4cur=%s p4max=%s p7cur=%s p7max=%s load=%s\n' \
        "$(date -Is)" "$cpu" "$chg" "$bat" \
        "$(freq policy4 scaling_cur_freq)" "$(freq policy4 scaling_max_freq)" \
        "$(freq policy7 scaling_cur_freq)" "$(freq policy7 scaling_max_freq)" \
        "$load" >> "$MON_LOG"
    trim_log
    sleep "$MON_INTERVAL"
done
