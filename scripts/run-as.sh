#!/bin/bash
# run-as — drop privileges to a target user and run a command. Used by the
# chroot's boot hooks (/etc/host-hooks/*.hook run as root) to launch
# user-owned services; usable interactively too.
#
# Installed at /usr/local/sbin/run-as by agents_setup.sh. Source of truth is
# scripts/run-as.sh in the repo.
#
# Usage:  run-as <user> -- <cmd> [args...]
#   run-as user -- tmux-service hermes -- hermes gateway run --replace
#   run-as user -- sh -c 'cd ~/freeloader && exec .venv/bin/uvicorn ...'
#
# Thin wrapper over `su -l <user> -s /bin/sh -c`:
#   -l  login shell — clean env + the target user's PATH (~/.local/bin for uv).
#   -s /bin/sh  don't depend on the target's login shell being script-safe.
#
# bash (not /bin/sh) so we can `printf %q` the argv into the single string
# `su -c` takes — the same quoting tmux-service uses, so nested invocations
# like `run-as user -- tmux-service x -- sh -c '...'` survive intact.
set -e

if [ $# -lt 2 ]; then
    echo "usage: run-as <user> -- <cmd> [args...]" >&2
    exit 2
fi

user=$1; shift
[ "$1" = "--" ] && shift

if [ $# -eq 0 ]; then
    echo "run-as: no command given after user" >&2
    exit 2
fi

cmd=$(printf '%q ' "$@")
exec su -l "$user" -s /bin/sh -c "$cmd"
