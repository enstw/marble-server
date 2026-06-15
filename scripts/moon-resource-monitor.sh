#!/bin/sh
# moon-resource-monitor — passive temps, cpufreq + resource-accumulator logger
# for the moon server.
#
# EVIDENCE ONLY. It samples /sys and /proc and appends a line to a log; it NEVER
# writes a control node. So it cannot fight the vendor thermal daemon (mi_thermald)
# and has nothing to oscillate — unlike a reactive throttler. Two jobs:
#   1. THERMAL — peak temp/freq data to choose & verify the CPU cap, so the next
#      incident has evidence instead of a bare `reboot` boot tag.
#   2. ACCUMULATORS — memory/swap/slab/thread/pid TREND. A reboot that comes hours
#      into a steady workload is NOT a heat signature: temperature is an equilibrium
#      of generation vs. dissipation and asymptotes within minutes — it does not
#      integrate over hours. A delayed reset fits a monotonically GROWING resource
#      (→ OOM → kernel panic/watchdog) far better. Heat is a level; a leak is a
#      slope, and a single snapshot can't see a slope — only this trail can. Prime
#      suspect: the agent crash-loop as a leak pump (orphaned MCP children per
#      restart). See docs/LESSONS.md §4 and the 2026-06-15 incident.
#
# Deployed to /usr/local/sbin/moon-resource-monitor and launched detached by
# /etc/host-hooks/60-resource.hook at boot. Source of truth: scripts/moon-resource-monitor.sh.
#
# Each sample line (temps °C, freqs kHz, memory MiB):
#   <iso8601> cpu=<max cpu-1-* °C> chg=<charger_therm0 °C> bat=<battery °C> \
#     p4cur=<kHz> p4max=<kHz> p7cur=<kHz> p7max=<kHz> load=<1m> \
#     memav=<MemAvailable> swfree=<SwapFree> commit=<Committed_AS> slab=<Slab> \
#     kstk=<KernelStack ~thread proxy> pids=<visible /proc count>
# Logging p4max/p7max every sample doubles as the cap STICKINESS check: if the vendor
# stack ever rewrites scaling_max_freq back to cpuinfo_max, it shows up right here.
# The memav/swfree/commit/slab/kstk/pids columns are the LEAK TRAIL — read their
# SLOPE across hours, not any single value: memav sliding toward 0 (or swfree
# falling) before a reset is the memory-leak smoking gun; flat memav across a reset
# means look at pids/kstk (thread/FD growth) instead. NB: pids is the CHROOT's /proc
# view (partial — not all host PIDs visible), but the slope within a boot is valid.
#
# Stop:  pkill -f /usr/local/sbin/moon-resource-monitor
# Tune:  /etc/moon-resource.conf  (MON_INTERVAL / MON_LOG / MON_LOG_MAX_BYTES / MON_LOG_KEEP)
#
# No `set -e`: a transient sysfs read hiccup must never kill the logger. Every read
# is guarded so one bad sample degrades to "?" rather than exiting the loop.

CONF=/etc/moon-resource.conf
[ -r "$CONF" ] && . "$CONF"
MON_INTERVAL=${MON_INTERVAL:-30}
MON_LOG=${MON_LOG:-/var/log/moon-resource.log}
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

# /proc/meminfo field ($1) in MiB (integer), or "?" if absent. meminfo "kB" is KiB.
mem_mb() {
    v=$(awk -v k="$1:" '$1==k{print $2; exit}' /proc/meminfo 2>/dev/null)
    [ -n "$v" ] && echo $(( v / 1024 )) || echo "?"
}

# Count of PIDs visible in /proc. CHROOT view is partial (hidepid + the chroot's
# own /proc), so this is a relative trend within a boot, not an absolute host count.
pid_count() { ls -d /proc/[0-9]* 2>/dev/null | wc -l | tr -d ' '; }

trim_log() {
    sz=$(wc -c < "$MON_LOG" 2>/dev/null || echo 0)
    if [ "$sz" -gt "$MON_LOG_MAX_BYTES" ] 2>/dev/null; then
        tail -n "$MON_LOG_KEEP" "$MON_LOG" > "$MON_LOG.tmp" 2>/dev/null && mv "$MON_LOG.tmp" "$MON_LOG"
    fi
}

mkdir -p "$(dirname "$MON_LOG")" 2>/dev/null
echo "=== moon-resource-monitor start $(date -Is) interval=${MON_INTERVAL}s cpu_zones=[$CPU_TEMPS] ===" >> "$MON_LOG"

while true; do
    cpu=$(mc_to_c "$(read_max "$CPU_TEMPS")")
    chg=$(mc_to_c "$(cat "$CHG_TEMP" 2>/dev/null)")
    bat=$(mc_to_c "$(cat "$BAT_TEMP" 2>/dev/null)")
    load=$(cut -d' ' -f1 /proc/loadavg 2>/dev/null || echo "?")
    printf '%s cpu=%s chg=%s bat=%s p4cur=%s p4max=%s p7cur=%s p7max=%s load=%s memav=%s swfree=%s commit=%s slab=%s kstk=%s pids=%s\n' \
        "$(date -Is)" "$cpu" "$chg" "$bat" \
        "$(freq policy4 scaling_cur_freq)" "$(freq policy4 scaling_max_freq)" \
        "$(freq policy7 scaling_cur_freq)" "$(freq policy7 scaling_max_freq)" \
        "$load" \
        "$(mem_mb MemAvailable)" "$(mem_mb SwapFree)" "$(mem_mb Committed_AS)" \
        "$(mem_mb Slab)" "$(mem_mb KernelStack)" "$(pid_count)" >> "$MON_LOG"
    trim_log
    sleep "$MON_INTERVAL"
done
