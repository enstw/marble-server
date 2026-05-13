#!/bin/bash
# tmux-service — run a long-lived command inside a detached tmux session with
# crash-loop recovery and log tee. This is the chroot's stand-in for a systemd
# unit: no PID 1 here, so a named tmux session is our "unit" and the while-true
# wrapper is our Restart=always.
#
# Installed at /usr/local/bin/tmux-service by agents_setup.sh. Source of truth
# is scripts/tmux-service.sh in the repo.
#
# Usage: tmux-service <name> -- <cmd> [args...]
#
# Example (run as user):
#   tmux-service openclaw -- openclaw gateway --port 18789
#   tmux-service hermes   -- hermes gateway start
#
# Behavior:
#   - If a tmux session named <name> already exists, it is killed first.
#   - A fresh detached session is created running:
#       while true; do <cmd>; sleep 2; done 2>&1 | tee -a <logfile>
#   - Log lives under $XDG_STATE_HOME/moon-agents (default ~/.local/state/moon-agents).
#   - Attach over ssh:  tmux attach -t <name>
#   - Stop the service: tmux kill-session -t <name>
#
# Notes:
#   - Always invoked as the user that should OWN the agent — do not run via
#     sudo/su from a different login. Tmux server + socket are per-uid; mixing
#     owners creates two unreachable servers.

set -e

NAME=""
while [ $# -gt 0 ]; do
    case "$1" in
        --) shift; break;;
        -h|--help)
            sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'
            exit 0;;
        -*)
            echo "tmux-service: unknown flag: $1" >&2
            exit 2;;
        *)
            if [ -z "$NAME" ]; then NAME=$1; shift
            else break; fi;;
    esac
done

if [ -z "$NAME" ] || [ $# -eq 0 ]; then
    echo "usage: tmux-service <name> -- <cmd> [args...]" >&2
    exit 2
fi

if ! command -v tmux >/dev/null 2>&1; then
    echo "tmux-service: tmux not installed — run agents_setup.sh first" >&2
    exit 3
fi

LOG_DIR=${XDG_STATE_HOME:-$HOME/.local/state}/moon-agents
mkdir -p "$LOG_DIR"
LOG=$LOG_DIR/$NAME.log

# Shell-quote each argument with %q so metachars survive tmux's single-string
# command layer. Plain $* would flatten `sh -c "a; b"` into `sh -c a; b` and
# silently break anything with a quoted arg.
CMD=$(printf '%q ' "$@")

# The loop body is built as a single string the tmux pane's shell will exec.
# Escaping $() and $? so they evaluate inside the pane, not here.
LOOP="while true; do echo \"[\$(date -Is)] start $NAME\"; $CMD; echo \"[\$(date -Is)] $NAME exited rc=\$?\"; sleep 2; done 2>&1 | tee -a \"$LOG\""

if tmux has-session -t "$NAME" 2>/dev/null; then
    tmux kill-session -t "$NAME"
fi

tmux new-session -d -s "$NAME" "$LOOP"

sleep 1
echo "=== tmux-service: $NAME ==="
tmux list-sessions 2>/dev/null | grep "^$NAME:" || {
    echo "(session $NAME not running — check $LOG)" >&2
    exit 4
}
echo "log:    $LOG"
echo "attach: tmux attach -t $NAME"
echo "stop:   tmux kill-session -t $NAME"
