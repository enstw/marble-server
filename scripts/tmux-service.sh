#!/bin/bash
# tmux-service — run a long-lived command inside a detached tmux session with
# crash-loop recovery. This is the chroot's stand-in for a systemd unit: no PID 1
# here, so a named tmux session is our "unit" and the while-true wrapper is our
# Restart=always.
#
# The supervised command runs ON the tmux pane's pty (a real tty that carries the
# pane's size and receives SIGWINCH on resize), so an interactive / full-screen TUI
# (e.g. `claude --channels`) stays interactive AND tracks the terminal — no external
# pty shim, no pinned width. Only THIS supervisor's bookkeeping (start / exited /
# fast-fail / circuit-open) is written to the logfile; the command's own output lives
# in the pane — view it live with `tmux attach -t <name>` (and in the command's own
# files, if it keeps any).
#
# Installed at /usr/local/bin/tmux-service by agents_setup.sh. Source of truth
# is scripts/tmux-service.sh in the repo.
#
# Usage: tmux-service <name> -- <cmd> [args...]
#
# Example (run as user):
#   tmux-service work-channel -- /home/user/cowork/work/bin/channel-launch
#
# Behavior:
#   - If a tmux session named <name> already exists, it is killed first.
#   - A fresh detached session re-runs <cmd> with a crash-loop guard: a run that
#     fails in under HEALTHY_SECS counts as a fast-fail; consecutive fast-fails
#     back off exponentially (BASE_SLEEP→BACKOFF_CAP) and, after MAX_FAILS in a
#     row, the circuit OPENS — the session logs "CIRCUIT OPEN" and exits instead
#     of restart-storming. A run lasting >= HEALTHY_SECS resets the gate.
#   - <cmd> runs on the pane pty; only supervisor bookkeeping is logged.
#   - Bookkeeping log lives under $XDG_STATE_HOME/moon-agents (default ~/.local/state/moon-agents).
#   - Attach over ssh:  tmux attach -t <name>
#   - Stop the service: tmux kill-session -t <name>
#   - Tune per-invocation via env: TMUX_SVC_HEALTHY_SECS / _MAX_FAILS /
#     _BASE_SLEEP / _BACKOFF_CAP (defaults 60 / 10 / 2 / 300).
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

# Crash-loop guard (a poor man's systemd StartLimit). Without it, a command that
# fails instantly restarts every 2s forever — on moon that once meant ~450
# Node+MCP cold-starts over ~5h, cooking the SoC into repeated thermal/watchdog
# resets (incident 2026-06-15). A run shorter than HEALTHY_SECS is a fast-fail;
# consecutive fast-fails back off exponentially and, after MAX_FAILS in a row,
# the circuit opens and the loop exits. A run >= HEALTHY_SECS resets the gate.
HEALTHY_SECS=${TMUX_SVC_HEALTHY_SECS:-60}   # a run >= this "actually started" → reset
MAX_FAILS=${TMUX_SVC_MAX_FAILS:-10}         # consecutive fast-fails → open circuit, stop
BASE_SLEEP=${TMUX_SVC_BASE_SLEEP:-2}        # restart delay after a healthy run / 1st fail
BACKOFF_CAP=${TMUX_SVC_BACKOFF_CAP:-300}    # max backoff between restart attempts (s)

# Logging is bookkeeping-only. We do NOT pipe the loop through `tee`: a pipe is not
# a tty, and a piped stdout would push an interactive command into headless mode
# (claude --channels flips to --print and dies — incident 2026-06-15, formerly
# worked around with an external pty). Leaving $CMD unredirected keeps it on the
# pane's pty (a real tty with the pane's real size + SIGWINCH), so it stays
# interactive and tracks the terminal with no pinned width. Each supervisor echo is
# redirected to $LOG instead; the command's own output stays in the pane.
LOG_BK=" >> \"$LOG\""

# The loop body is built as a single string the tmux pane's shell will exec.
# Build-time vars ($CMD/$NAME/$LOG + the numeric knobs) are substituted now;
# runtime vars (\$rc/\$dur/\$fails/\$delay/\$(date …)) are escaped to evaluate
# inside the pane. $LOG_BK sends each bookkeeping echo to the logfile; $CMD is left
# unredirected so it inherits the pane pty.
LOOP="fails=0; delay=$BASE_SLEEP; \
while true; do \
  t0=\$(date +%s); echo \"[\$(date -Is)] start $NAME\"$LOG_BK; \
  $CMD; rc=\$?; \
  dur=\$(( \$(date +%s) - t0 )); \
  echo \"[\$(date -Is)] $NAME exited rc=\$rc after \${dur}s\"$LOG_BK; \
  if [ \"\$dur\" -ge $HEALTHY_SECS ]; then fails=0; delay=$BASE_SLEEP; \
  else \
    fails=\$(( fails + 1 )); \
    if [ \"\$fails\" -ge $MAX_FAILS ]; then \
      echo \"[\$(date -Is)] $NAME CIRCUIT OPEN: \$fails consecutive fast-fails (<${HEALTHY_SECS}s) — stopping restarts. Fix the command, then re-run: tmux-service $NAME -- ...\"$LOG_BK; \
      break; \
    fi; \
    echo \"[\$(date -Is)] $NAME fast-fail #\$fails — backing off \${delay}s\"$LOG_BK; \
  fi; \
  sleep \$delay; \
  delay=\$(( delay * 2 )); [ \$delay -gt $BACKOFF_CAP ] && delay=$BACKOFF_CAP; \
done"

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
