#!/bin/sh
# android — Android-side device controls callable from inside the Ubuntu chroot.
#
# Subcommands:
#   lock              put the device into screen-off / low-power state
#   unlock [--stayon] wake the screen and dismiss the keyguard
#   beep              play a built-in tone (audible alert)
#   play <file>       play an audio file (readable by the Termux:API app)
#   volume up|down [n] adjust the active audio stream by n steps (default 1)
#
# Android binaries like `input` / `wm` / `svc` are dynamically linked against
# /system/bin/linker64 (absolute path) and won't exec from inside the Ubuntu
# chroot directly. Each subcommand chroots into PID 1's root for the duration
# of the call: PID 1 is Android's init, which lives outside our chroot, so
# /proc/1/root is the real Android filesystem. From Android directly the chroot
# is a no-op (init's root is already /), so a single code path covers both
# contexts.
#
# Why `unlock` matters as a power lever: Android drops the CPU into a
# lower-power state when the screen is off, and Doze policy nibbles further at
# throughput for background workloads. Even with the lockscreen disabled (the
# standing policy on this device so CE storage auto-unlocks at boot — see
# docs/INSTALLATION.md § "CE storage prerequisite"), the screen-off power state
# is measurable at the Ubuntu workload layer. `unlock` is the manual override
# for when you need governors pinned back to performance.
#
# Audible alerts (`beep` / `play`): the Ubuntu chroot has no audio device
# (/dev/snd absent), and this Lineage build ships no tinyalsa/stagefright CLI
# and no media-player app that auto-plays a VIEW intent. So playback is
# delegated to Termux:API's MediaPlayer (decodes + routes via Android's audio
# framework — correct routing, fully headless). The call must originate from
# the Termux uid (the Termux:API socket round-trip hangs for a root caller, and
# this build has no `su` to drop uid), so it is dispatched through Termux's own
# RunCommandService. One-time prereqs on the device:
#   - install the Termux:API APK (same source as Termux) + `pkg install termux-api`
#   - set `allow-external-apps = true` in ~/.termux/termux.properties, then
#     `termux-reload-settings` (or restart Termux)
# `beep` synthesizes a gravitational-wave inspiral chirp once to /sdcard via the chroot's ffmpeg;
# `play <file>` plays any file the Termux:API app can read (keep it on /sdcard).
# See docs/MAINTENANCE.md §1 "Audible alerts". NOTE: like lock/unlock, the
# `am startservice` binder call may hit the agent-context limitation documented
# in MAINTENANCE.md §2.8 (works from an interactive ssh session; agent-driven
# use is to be verified).
#
# Deployment: ssh_setup.sh installs this at /usr/local/sbin/android (root-only,
# since chroot needs CAP_SYS_CHROOT), with a NOPASSWD sudoers entry in
# /etc/sudoers.d/50-moon-helpers. The script self-elevates (re-exec via sudo
# when not root — see below), so a bare `android <cmd>` works from any shell
# without a separate PATH wrapper.
#
# Usage:
#   android lock                                # from user ssh (self-elevates)
#   android unlock [--stayon]
#   sudo android lock                           # explicit; also fine
#   ssh moon-user android unlock                # from a workstation
#   adb shell su -c 'sh /data/data/com.termux/files/home/android.sh lock'  # from Android directly

# Self-elevate. A PATH-resident `android` resolves to this sbin copy first
# (/usr/local/sbin precedes /usr/local/bin), so a separate /usr/local/bin
# wrapper would be permanently shadowed — a bare `android` would run here
# UNPRIVILEGED and the chroot escape below would fail with ENOENT under /proc's
# hidepid. Re-exec through sudo (NOPASSWD) when not already root, so bare /
# `sudo` / `ssh moon-user android …` all reach root here. From Android directly
# (adb shell su) id is already 0, so this is a no-op.
if [ "$(id -u)" -ne 0 ]; then
    exec sudo /usr/local/sbin/android "$@"
fi

usage() {
    cat >&2 <<'EOF'
usage: android <command> [args]

commands:
  lock              screen off / low-power (KEYCODE_SLEEP)
  unlock [--stayon] wake screen + dismiss keyguard; --stayon also keeps the
                    display on while powered (svc power stayon true), persistent
                    until cleared with `svc power stayon false`
  beep              play a built-in tone via Termux:API MediaPlayer
  play <file>       play an audio file (readable by the Termux:API app; keep
                    it on /sdcard). Requires Termux:API + termux-api pkg +
                    allow-external-apps=true (see header / MAINTENANCE.md §1)
  volume up|down [n] adjust the active audio stream by n steps (default 1) via
                    KEYCODE_VOLUME_UP/DOWN; adjusts the media stream while audio
                    is playing, else the ring stream
EOF
    exit 2
}

cmd=${1:-}
[ "$#" -gt 0 ] && shift

case "$cmd" in
    lock)
        [ "$#" -eq 0 ] || { echo "android lock: unexpected arg: $1" >&2; exit 2; }
        # KEYCODE_SLEEP = 223. Unambiguous — always sleeps, no matter the
        # current screen state. Prefer over KEYCODE_POWER (26) which toggles.
        exec chroot /proc/1/root /system/bin/input keyevent 223
        ;;
    unlock)
        stayon=0
        for arg in "$@"; do
            case "$arg" in
                --stayon) stayon=1 ;;
                *) echo "android unlock: unknown arg: $arg" >&2; exit 2 ;;
            esac
        done
        # KEYCODE_WAKEUP = 224. Safe to call when already awake — no-op.
        # wm dismiss-keyguard: no-op when lockscreen is disabled; meaningful
        # if a PIN/pattern ever gets re-enabled on the device.
        cmds='input keyevent 224; wm dismiss-keyguard'
        [ "$stayon" = 1 ] && cmds="$cmds; svc power stayon true"
        exec chroot /proc/1/root /system/bin/sh -c "$cmds"
        ;;
    beep|play)
        # Audible alert via Termux:API MediaPlayer (see header for the why and
        # the one-time device prereqs). `beep` plays a built-in tone; `play`
        # takes a file path the Termux:API app can read (keep it on /sdcard).
        TONE=/sdcard/.moon-beep.wav
        if [ "$cmd" = beep ]; then
            [ "$#" -eq 0 ] || { echo "android beep: unexpected arg: $1" >&2; exit 2; }
            file=$TONE
            if [ ! -s "$file" ]; then
                command -v ffmpeg >/dev/null 2>&1 || {
                    echo "android beep: ffmpeg not found in chroot to synthesize the tone" >&2; exit 1; }
                # A ~3s gravitational-wave inspiral "chirp" (à la LIGO): the
                # Newtonian inspiral phase Phi ~ (tc-t)^(5/8) makes the instantaneous
                # freq diverge toward the merge at tc=2.7s; strain amplitude ~
                # (tc-t)^(-1/4) swells in; then a damped ~200Hz ringdown. NB:
                # ffmpeg's `sine` lavfi source is low-amplitude (~-25dB), so we
                # drive aevalsrc into a limiter and reclaim the headroom
                # (volume=2.9dB) -> mean ~-4dB, peak ~0dBFS (loud).
                ffmpeg -hide_banner -loglevel error -f lavfi \
                    -i "aevalsrc='if(lt(t,2.7),min(0.25*pow(max(2.7-t,0.0008),-0.25),0.95)*sin(802*pow(max(2.7-t,0.0008),0.625)),0.95*exp(-(t-2.7)/0.12)*sin(2*PI*200*(t-2.7))):d=3.0:s=48000'" \
                    -af "afade=t=in:st=0:d=0.01,afade=t=out:st=2.9:d=0.1,alimiter=level_in=4:limit=0.99,volume=2.9dB,aformat=channel_layouts=stereo" \
                    -c:a pcm_s16le -y "$file" \
                    || { echo "android beep: failed to synthesize tone" >&2; exit 1; }
            fi
        else
            [ "$#" -eq 1 ] || { echo "usage: android play <file>" >&2; exit 2; }
            file=$1
            case "$file" in
                *,*) echo "android play: comma in path unsupported (RUN_COMMAND arg delimiter)" >&2; exit 2 ;;
            esac
            [ -e "$file" ] || echo "android play: warning: '$file' not visible from chroot" >&2
        fi
        # RunCommandService runs termux-media-player as the Termux uid. Pass the
        # binary path and file as positional args after -c (become $1/$2 in the
        # Android shell) so paths with spaces survive without nested quoting.
        exec chroot /proc/1/root /system/bin/sh -c '
            export PATH=/system/bin:/system/xbin
            exec am startservice --user 0 \
                -n com.termux/com.termux.app.RunCommandService \
                -a com.termux.RUN_COMMAND \
                --es com.termux.RUN_COMMAND_PATH "$1" \
                --esa com.termux.RUN_COMMAND_ARGUMENTS "play,$2" \
                --ez com.termux.RUN_COMMAND_BACKGROUND true
        ' moon-android /data/data/com.termux/files/usr/bin/termux-media-player "$file"
        ;;
    volume)
        dir=${1:-}
        [ -n "$dir" ] || { echo "usage: android volume up|down [steps]" >&2; exit 2; }
        shift
        steps=${1:-1}
        case "$dir" in
            up)   key=24 ;;   # KEYCODE_VOLUME_UP
            down) key=25 ;;   # KEYCODE_VOLUME_DOWN
            *) echo "android volume: expected up|down, got: $dir" >&2; exit 2 ;;
        esac
        case "$steps" in
            ''|*[!0-9]*) echo "android volume: steps must be a positive integer: $steps" >&2; exit 2 ;;
        esac
        [ "$steps" -ge 1 ] || { echo "android volume: steps must be >= 1" >&2; exit 2; }
        # Volume keyevents adjust the *active* stream — media while audio is
        # playing, otherwise ring. Same chroot escape + agent-context caveat as
        # lock/unlock (MAINTENANCE.md §2.8). Repeat the keyevent `steps` times.
        cmds=""
        i=0
        while [ "$i" -lt "$steps" ]; do cmds="$cmds input keyevent $key;"; i=$((i + 1)); done
        exec chroot /proc/1/root /system/bin/sh -c "$cmds"
        ;;
    -h|--help|help)
        usage
        ;;
    *)
        [ -n "$cmd" ] && echo "android: unknown command: $cmd" >&2
        usage
        ;;
esac
