#!/system/bin/sh
# ssh_setup.sh — configure OpenSSH + non-root `user` inside the Ubuntu chroot.
#
# Reads pubkeys from /data/data/com.termux/files/home/authorized_keys so key
# rotation is a data edit, not a script edit. Idempotently ensures `user` with
# a locked password — pubkey SSH works immediately; run `passwd user` once
# post-rebuild if sudo is needed.
#
# Invoke from Android: adb shell su -c 'sh /data/data/com.termux/files/home/ssh_setup.sh'

set -e

UBUNTU=/data/data/com.termux/files/home/ubuntu
KEYS=/data/data/com.termux/files/home/authorized_keys
REBOOT_SH=/data/data/com.termux/files/home/reboot.sh
ANDROID_LOCK_SH=/data/data/com.termux/files/home/android-lock.sh
ANDROID_UNLOCK_SH=/data/data/com.termux/files/home/android-unlock.sh

if [ ! -r "$KEYS" ]; then
    echo "ERROR: $KEYS missing — push scripts/authorized_keys first" >&2
    exit 1
fi
if [ ! -r "$REBOOT_SH" ]; then
    echo "ERROR: $REBOOT_SH missing — push scripts/reboot.sh first" >&2
    exit 1
fi
if [ ! -r "$ANDROID_LOCK_SH" ] || [ ! -r "$ANDROID_UNLOCK_SH" ]; then
    echo "ERROR: android-lock.sh/android-unlock.sh missing — push scripts/android-{lock,unlock}.sh first" >&2
    exit 1
fi

# Stage authorized_keys + reboot.sh + android-{lock,unlock}.sh from Android
# side into a temporary location. All get moved into the chroot's final
# locations below.
install -d -m 1777 "$UBUNTU/tmp"
install -m 0600 "$KEYS" "$UBUNTU/tmp/authorized_keys"
install -m 0755 "$REBOOT_SH" "$UBUNTU/tmp/reboot"
install -m 0755 "$ANDROID_LOCK_SH" "$UBUNTU/tmp/android-lock"
install -m 0755 "$ANDROID_UNLOCK_SH" "$UBUNTU/tmp/android-unlock"

exec sh /data/data/com.termux/files/home/start_ubuntu.sh << 'CHROOT_CMD'
set -e

install -d -m 0755 /var/run/sshd
cat > /etc/ssh/sshd_config.d/10-moon.conf <<'EOF'
Port 2222
ListenAddress 0.0.0.0
PermitRootLogin no
PasswordAuthentication no
PubkeyAuthentication yes
ChallengeResponseAuthentication no
UsePAM yes
X11Forwarding no
PrintMotd no
AcceptEnv LANG LC_* COLORTERM
Subsystem sftp /usr/lib/openssh/sftp-server

# Hardening: Clean up dead/hung connections after ~2 minutes of inactivity.
# This prevents ghost processes from holding sockets open.
ClientAliveInterval 30
ClientAliveCountMax 4
EOF

# Ensure True Color is advertised globally inside the chroot.
install -d -m 0755 /etc/profile.d
cat > /etc/profile.d/10-truecolor.sh <<'EOF'
export COLORTERM=truecolor
EOF
chmod 0644 /etc/profile.d/10-truecolor.sh

# Provide automatic tmux session management for SSH logins.
# Creates independent sessions or reattaches to unattached ones,
# explicitly avoiding AI agent service sessions by using the 'ssh_' prefix.
#
# Sourced from two places so both login shells get it:
#   - bash: /etc/profile → /etc/profile.d/99-tmux-autostart.sh
#   - zsh:  /etc/zsh/zlogin (one-line source of the same file)
# zsh on Debian/Ubuntu does not pull in /etc/profile.d/* by default, so a
# bash-only install silently does nothing for `user` (their shell is zsh).
# Interactivity guard is `case $- in *i*)` rather than `[ "$PS1" ]` because
# zsh sets PS1 even in non-interactive shells — the latter would wrongly
# trigger tmux on `ssh moon-user <cmd>`.
install -d -m 0755 /etc/profile.d
cat > /etc/profile.d/99-tmux-autostart.sh <<'EOF'
case $- in *i*) ;; *) return 0 2>/dev/null || exit 0 ;; esac
if [ -z "$TMUX" ] && [ -n "$SSH_TTY" ] && command -v tmux >/dev/null 2>&1; then
    # Find the first unattached session that starts with ssh_
    UNATTACHED=$(tmux ls -F '#{session_name} #{session_attached}' 2>/dev/null | awk '$1 ~ /^ssh_/ && $2 == "0" {print $1; exit}')
    if [ -n "$UNATTACHED" ]; then
        exec tmux attach-session -t "$UNATTACHED"
    else
        # Use the shell PID for a unique session name
        exec tmux new-session -s "ssh_$$"
    fi
fi
EOF
chmod 0644 /etc/profile.d/99-tmux-autostart.sh

# zsh hook: source the same file from /etc/zsh/zlogin. Idempotent — re-runs
# of ssh_setup.sh don't stack duplicate lines.
install -d -m 0755 /etc/zsh
ZLOGIN=/etc/zsh/zlogin
ZLINE='[ -r /etc/profile.d/99-tmux-autostart.sh ] && . /etc/profile.d/99-tmux-autostart.sh'
touch "$ZLOGIN"
grep -qxF "$ZLINE" "$ZLOGIN" || printf '\n# tmux autostart for SSH logins (installed by ssh_setup.sh)\n%s\n' "$ZLINE" >> "$ZLOGIN"
chmod 0644 "$ZLOGIN"

# Pin tmux's default-shell to zsh. tmux's default-shell is decided once per
# server: at first-launch it reads $SHELL → getpwuid → /bin/sh and caches the
# result for the life of the server. Without this file, if the first ssh-in
# happens in a context where $SHELL is unset (or the server was started from
# a /bin/sh-ish parent), every window/pane afterwards spawns /bin/sh — even
# when the login shell that triggered the autostart was zsh. Pinning it in
# /etc/tmux.conf makes the choice deterministic regardless of how the server
# was first spawned.
cat > /etc/tmux.conf <<'EOF'
set-option -g default-shell /bin/zsh
# True Color (24-bit) support. Keep this here rather than in agents_setup.sh:
# ssh_setup.sh runs at boot, so it is the authoritative tmux config writer.
set-option -g default-terminal "screen-256color"
set-option -sa terminal-overrides ",xterm*:Tc"
# Touchpad / mouse scroll into copy-mode and back through the scrollback.
set-option -g mouse on
# Natural-scroll bindings: wheel-down enters copy-mode and pages back into
# history (mirror of tmux's default WheelUpPane behaviour, on the opposite
# wheel); wheel-up in a normal pane is a no-op so it doesn't enter copy-mode
# in the wrong direction. Inside copy-mode the wheel directions are swapped.
bind-key -T root WheelDownPane if-shell -F -t = "#{?pane_in_mode,1,#{alternate_on}}" "send-keys -M" "copy-mode -e ; send-keys -M"
bind-key -T root WheelUpPane if-shell -F -t = "#{?pane_in_mode,1,#{alternate_on}}" "send-keys -M" ""
bind-key -T copy-mode    WheelUpPane   send-keys -X scroll-down
bind-key -T copy-mode    WheelDownPane send-keys -X scroll-up
bind-key -T copy-mode-vi WheelUpPane   send-keys -X scroll-down
bind-key -T copy-mode-vi WheelDownPane send-keys -X scroll-up
EOF
chmod 0644 /etc/tmux.conf

usermod -s /bin/bash root 2>/dev/null || true

# Ensure zsh + sudo are present before we touch `user` — both are referenced
# below (login shell, sudo group, tmux default-shell). apt-get install is a
# no-op if already installed, so this is safe to re-run.
apt-get install -y zsh sudo >/dev/null

# Idempotent non-root user. Locked-password on creation so pubkey SSH works
# immediately without baking a hash into the repo; one-shot `passwd user`
# unlocks sudo post-rebuild.
if ! id user >/dev/null 2>&1; then
    useradd -m -s /bin/zsh user
    usermod -aG sudo user
    passwd -l user
    echo "[ssh_setup] created user (password locked). run 'passwd user' to enable sudo."
fi
# Pin `user`'s login shell to zsh on every run — older revs of this script
# created the account with /bin/bash, so existing chroots need fixing up.
usermod -s /bin/zsh user
install -d -m 0700 -o user -g user /home/user/.ssh
install -m 0600 -o user -g user /tmp/authorized_keys /home/user/.ssh/authorized_keys
rm -f /tmp/authorized_keys

# Install the SIGHUP-fast reboot script at /usr/local/sbin/reboot. Shadows
# Ubuntu's systemd-wrapper /sbin/reboot — in-chroot reboot(2) works (we have
# CAP_SYS_BOOT) but bypasses Android init's graceful-shutdown sequence, and
# ssh hangs because the kernel panics before sshd can close the socket. The
# script hops out to Android's init via /proc/1/root, schedules toybox reboot
# detached, then SIGHUPs the per-session sshd so the ssh client returns within
# tens of ms instead of waiting for stdio EOF. Source: scripts/reboot.sh.
# Lives under /usr/local/sbin which dpkg/apt never touch, so it survives
# package upgrades and chroot rebuilds (rebuild re-runs ssh_setup.sh).
install -m 0755 -o root -g root /tmp/reboot /usr/local/sbin/reboot
rm -f /tmp/reboot

# Install android-lock / android-unlock. Same pattern — these self-escape via
# chroot /proc/1/root (CAP_SYS_CHROOT needed), so the real scripts live in
# root-only territory and PATH wrappers + NOPASSWD sudoers give `user` access.
install -m 0755 -o root -g root /tmp/android-lock /usr/local/sbin/android-lock
install -m 0755 -o root -g root /tmp/android-unlock /usr/local/sbin/android-unlock
rm -f /tmp/android-lock /tmp/android-unlock

# NOPASSWD sudoers for all three. Consolidated drop-in so /etc/sudoers.d/ stays
# tidy. Each target is an explicit path — sudoers globbing is off by default.
TMP_SUDO=$(mktemp)
cat > "$TMP_SUDO" <<'EOF'
user ALL=(root) NOPASSWD: /usr/local/sbin/reboot
user ALL=(root) NOPASSWD: /usr/local/sbin/android-lock
user ALL=(root) NOPASSWD: /usr/local/sbin/android-unlock
EOF
visudo -cf "$TMP_SUDO" >/dev/null
install -m 0440 -o root -g root "$TMP_SUDO" /etc/sudoers.d/50-moon-helpers
rm -f "$TMP_SUDO"

# PATH wrappers in /usr/local/bin. Lets `user` type bare `reboot`,
# `android-lock`, `android-unlock` from any shell (interactive or not, login
# or `ssh moon-user <cmd>` non-interactive) without aliases or PATH gymnastics
# — /usr/local/bin is in default PATH everywhere. Each wrapper is just `exec
# sudo` to the real binary; sudo finds the NOPASSWD entry via secure_path.
for cmd in reboot android-lock android-unlock; do
    cat > "/usr/local/bin/$cmd" <<EOF
#!/bin/sh
# Thin wrapper installed by ssh_setup.sh — see /usr/local/sbin/$cmd for
# the real implementation. NOPASSWD via /etc/sudoers.d/50-moon-helpers.
exec sudo /usr/local/sbin/$cmd "\$@"
EOF
    chmod 0755 "/usr/local/bin/$cmd"
done

# Clean up the old /root/reboot.sh layout from earlier revisions: the script
# itself, the per-script sudoers drop-in, the myshell alias file, and the
# /home/user/.bashrc lines older versions wrote there. Safe to remove
# unconditionally — re-runs of this script always re-create what's needed.
rm -f /root/reboot.sh /etc/sudoers.d/50-reboot /home/user/.zsh/50-reboot.zsh
if [ -f /home/user/.bashrc ]; then
    sed -i \
        -e "/^# Pre-authed reboot (no password)$/d" \
        -e "/^alias reboot='sudo \/root\/reboot'$/d" \
        -e "/^alias reboot='sudo \/root\/reboot\.sh'$/d" \
        /home/user/.bashrc
fi

# Forcefully clean up any stale listeners before starting.
pkill -9 -f '/usr/sbin/sshd' 2>/dev/null || true
sleep 1
/usr/sbin/sshd

sleep 1
echo --- sshd process ---
ps -eo pid,user,cmd | grep -E 'sshd( |$)' | grep -v grep
echo --- listening ---
ss -ltnp 2>/dev/null | grep 2222 || echo "(ss not finding :2222 — trying netstat)"
netstat -ltn 2>/dev/null | grep 2222 || echo "(netstat missing or not listening)"
echo --- auth keys ---
ls -la /home/user/.ssh/
CHROOT_CMD
