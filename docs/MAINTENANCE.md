# Maintenance & operations

Day-to-day operation, update procedures, troubleshooting, and recovery for a running `marble-server`. Prerequisite: install phases 1–3.5 complete.

Live values such as LAN IP, tailnet hostname, SSH identity path, and ADB serial live in the gitignored `config/moon.env`. Source it in a private checkout when you want shell variables:

```
set -a
. config/moon.env
set +a
```

## 1. Daily operation

### Device settings (Android side, persistent)

These are set once and expected to stay set. Several are load-bearing — changing them breaks autostart or performance.

| Setting | Value | Why it matters |
| :--- | :--- | :--- |
| Developer Options → **Stay awake while charging** | On | Phone is always plugged in. Screen stays on → no DVFS downscaling, no screen-off throttle (see §3). |
| **Screen lock** | None (no PIN/pattern) | CE-encrypted storage auto-unlocks at boot so the `moon-ssh` KSU module can reach `/data/data/com.termux/files/` at `late_start service`. Re-enabling a lock **breaks autostart**. |
| **Airplane mode** | On | No SIM, no cellular; radio off permanently. |
| **Wi-Fi** | Always on | Primary uplink for LAN + tailnet. |
| Developer Options → **USB debugging** | On | Required for `adb` management path. |
| Developer Options → **OEM unlocking** | On (bootloader already unlocked) | Needed before any `fastboot flash` (OTAs, re-KSU). |

### Connect

| Alias | Reach | Auth | Lands as |
| :--- | :--- | :--- | :--- |
| `ssh moon` | Home LAN → `MOON_LAN_HOST:2222` | OpenSSH + `MOON_SSH_IDENTITY_FILE` | `user` |
| `ssh moon-ts` | Tailnet → `MOON_TAILNET_HOST:2222` | OpenSSH + `MOON_SSH_IDENTITY_FILE` | `user` |
| `ssh moon-user` | Tailnet → `MOON_TAILNET_HOST:2222` | OpenSSH + `MOON_SSH_IDENTITY_FILE` | `user` |
| `tailscale ssh root@moon` | Tailnet | Tailscale identity (no key file) | `root` |
| `tailscale ssh user@moon` | Tailnet | Tailscale identity (no key file) | `user` |

All aliases land **inside the chroot**. OpenSSH is non-root by design (`PermitRootLogin no`); use `sudo` from `user` for routine administration. Root paths are `tailscale ssh root@moon` where Tailscale ACLs allow it, or `adb shell su` from the Mac. To reach the Android side, use `adb shell` — there is no way to "nest-exit" the chroot from an ordinary SSH shell.

### Where logs live

| What | Path | Readable from |
| :--- | :--- | :--- |
| Autostart boot log (both sshd + tailscaled) | `/var/log/moon-ssh-boot.log` (preamble fallback `/data/local/tmp/moon-ssh-boot.log` — Android side, only relevant if stage-2 handoff failed) | inside chroot — plain `cat` |
| Tailscaled | `/var/log/tailscaled.log` | inside chroot |
| Thermal cap + monitor | `/var/log/moon-thermal.log` (30s samples: max cpu / charger / battery temps + `policy4/7` cur+max freqs; the max-freq columns double as the cap-stickiness check) | inside chroot |
| sshd | syslog — lost unless `rsyslog` installed | — |

> **Why sshd has no log file:** the chroot has no syslog daemon. sshd writes to `syslog(3)` → `/dev/log`, which is not wired up. Install `rsyslog` in the chroot if you want persistent SSH logs.

### Where state lives

| What | Path | Survives |
| :--- | :--- | :--- |
| Ubuntu rootfs | `/data/data/com.termux/files/home/ubuntu/` | reboots; lost if Termux uninstalled or `/data` wiped |
| Tailscale identity | `/var/lib/tailscale/tailscaled.state` (inside chroot) | reboots; lost if chroot rebuilt |
| `user` account + home | `/etc/passwd`, `/home/user/` (inside chroot) | reboots; re-provisioned (locked) by `ssh_setup.sh` on chroot rebuild |
| `user` password hash | `/etc/shadow` (inside chroot) | reboots; **lost on chroot rebuild** — re-run `passwd user` once to re-enable sudo |
| SSH authorized_keys (user) | `/home/user/.ssh/authorized_keys` (inside chroot) | reboots; re-installed from the gitignored live `config/authorized_keys` each time `ssh_setup.sh` runs. Boot hooks are start-only (`10-sshd.hook` does not re-provision), so a manual in-chroot edit now **survives reboot** — but it is overwritten the next time you run `ssh_setup.sh` (rebuild or key rotation). Rotate keys by editing `config/authorized_keys` and re-running `ssh_setup.sh`, not by editing in the chroot. |
| KSU module | `/data/adb/modules/moon-ssh/` | reboots, Lineage OTAs, factory reset wipes |
| On-device script copies | `/data/data/com.termux/files/home/{start_ubuntu,ssh_setup,tailscale_setup,agents_setup,thermal_setup,reboot,android,tmux-service,run-as,moon-thermal-monitor}.sh` + `authorized_keys` + `moon-thermal.conf` + `{10-sshd,20-tailscale,50-agents,60-thermal}.hook` | reboots |
| Boot hooks (deployed) | `/etc/host-hooks/*.hook` (inside chroot) | reboots; **lost on chroot rebuild** — redeployed by the matching `*_setup.sh` (run in the rebuild sequence). `.disabled` enable/disable state is preserved across re-runs |
| Thermal cap config + monitor | `/etc/moon-thermal.conf` (cap freqs + monitor settings) + `/usr/local/sbin/moon-thermal-monitor` (inside chroot) | reboots; **lost on chroot rebuild** — redeployed by `thermal_setup.sh`. The config is install-only-if-absent, so on-device cap tuning survives a re-run |

### Manual restart

```
# Restart sshd (no reboot)
adb shell su -c 'sh /data/data/com.termux/files/home/ssh_setup.sh'

# Restart tailscaled (no reboot)
adb shell su -c 'sh /data/data/com.termux/files/home/tailscale_setup.sh'

# Enter chroot interactively (if SSH is down)
adb shell su -c '/data/data/com.termux/files/home/start_ubuntu.sh'

# Reboot phone — equivalent paths
adb reboot                  # from Mac, over USB
ssh moon reboot             # from Mac, over LAN SSH as user (NOPASSWD via wrapper)
ssh moon-user reboot        # from Mac, over tailnet SSH as user (NOPASSWD via wrapper)
```

`/usr/local/sbin/reboot` inside the chroot is the SIGHUP-fast reboot script provisioned by `ssh_setup.sh` (source: `scripts/reboot.sh`). It schedules the Android-side reboot detached via `chroot /proc/1/root`, then SIGHUPs the per-session sshd so the ssh client returns within tens of ms instead of hanging on the TCP socket until the kernel panics. Shadows Ubuntu's systemd-wrapper `/sbin/reboot` (`/usr/local/sbin` precedes `/usr/sbin` and `/sbin` in PATH). Lives under `/usr/local/sbin` which dpkg/apt never touch, so it survives package upgrades and chroot rebuilds.

`user` invokes it bare — the script **self-elevates**: `if [ "$(id -u)" -ne 0 ]; then exec sudo /usr/local/sbin/reboot "$@"; fi`. NOPASSWD comes from `/etc/sudoers.d/50-moon-helpers` (one drop-in, also covers `android`). So `reboot` and `ssh moon-user reboot` return with no password prompt, in interactive and non-interactive shells alike. There is deliberately **no** `/usr/local/bin/reboot` wrapper: `/usr/local/sbin` is PATH-first, so a wrapper there would be permanently shadowed by this script — a bare `reboot` would run unprivileged and the chroot escape would fail with ENOENT under `/proc`'s `hidepid`. `ssh_setup.sh` removes any stale wrapper on re-run. Older revisions used an alias in `/home/user/.zsh/50-reboot.zsh` and a separate `/root/reboot.sh` install — `ssh_setup.sh` cleans both up on re-run.

> **Shell config note:** `user`'s shell is `zsh`, set up via [enstw/myshell](https://github.com/enstw/myshell) — a personal zsh framework that generates `~/.zshrc` and `~/.zshenv` and auto-sources customs from `~/.zsh/*.zsh`. The reboot/lock/unlock commands no longer depend on this (self-elevation replaced the alias-in-drop-in approach), so re-running `ssh_setup.sh` after a fresh chroot rebuild doesn't require myshell to be installed first.

### Manual screen lock / unlock

Android drops the CPU into lower power states when the display is off, throttling Ubuntu workloads (see §3 "SSH throughput ~50%"). *Stay awake while charging* is the standing mitigation, but if the screen goes off anyway — cable glitch, accidental power tap, deliberate sleep — the `android` command flips the state back explicitly. `input keyevent`, `wm`, and `svc` are Android binaries (dynamically linked to `/system/bin/linker64` at absolute path), so they must run in Android context; the dispatcher self-escapes via `chroot /proc/1/root` (same pattern as `reboot.sh`).

`ssh_setup.sh` installs the single dispatcher at `/usr/local/sbin/android` (root-only — `chroot` needs `CAP_SYS_CHROOT`) and provisions `/etc/sudoers.d/50-moon-helpers` so `user` invokes it with no password prompt. The script **self-elevates** (`if [ "$(id -u)" -ne 0 ]; then exec sudo /usr/local/sbin/android "$@"; fi`) — there is no `/usr/local/bin/android` wrapper, because `/usr/local/sbin` is PATH-first and would shadow it (a bare `android` would then run unprivileged and the chroot escape would fail with ENOENT under `hidepid`; this was the original `android lock` bug). (The dispatcher replaced the former split `android-lock` / `android-unlock` commands; re-running `ssh_setup.sh` deletes their old `/usr/local/{sbin,bin}` binaries and any stale `/usr/local/bin/android` wrapper.) From any shell — interactive or not, in the chroot or via `ssh moon-user` — just type the command:

```
# Sleep the display (KEYCODE_SLEEP)
android lock                                # in-chroot user shell
ssh moon-user android lock                  # from a workstation
adb shell su -c 'sh /data/data/com.termux/files/home/android.sh lock'   # bypass the chroot entirely

# Wake + dismiss keyguard
android unlock
ssh moon-user android unlock

# Wake + set `svc power stayon true` (redundant on this device — Lineage
# already pins stay_on_while_plugged_in=15 via the Developer setting)
android unlock --stayon
```

Source: `scripts/android.sh`. State transitions via `dumpsys power | grep mWakefulness=` — `Awake` ↔ `Dozing`.

### In-chroot deploys without adb (`termux` helper)

Termux's home (`/data/data/com.termux/files/home`) is **not** bind-mounted into the chroot (the bind set in `start_ubuntu.sh` is deliberate), so re-provisioning normally means delivering the bootstrap scripts from a workstation with `adb push` + `adb shell su -c …`. When you're already on the device (e.g. over tailnet SSH, no workstation), `scripts/termux.sh` does the same three things from inside the chroot by escaping to Android via `chroot /proc/1/root` (same pattern as `reboot`/`android`):

```
sudo ./scripts/termux.sh cp <src> [dest-name]   # stage a file into Termux $HOME (re-applies source mode over FUSE)
sudo ./scripts/termux.sh rm <name>...           # remove file(s) from Termux $HOME
sudo ./scripts/termux.sh exec <cmd> [args...]   # run a command in Android (init) context
```

A full no-adb re-provision is then `cp` the changed scripts, `rm` any stale staged copies, then `exec sh …/ssh_setup.sh` — see §2.7 for the worked android-helper example.

Unlike `reboot` / `android`, this helper is **not installed** and is deliberately **not** wired into the `50-moon-helpers` NOPASSWD sudoers: `exec` runs an arbitrary command as root in Android context, so it must never be passwordless. It is root-only (needs `CAP_SYS_CHROOT`) and run in place as `sudo ./scripts/termux.sh …`. The installed helpers stay NOPASSWD precisely because each is a single fixed action behind its own explicit-path stanza — a generic exec cannot share that boundary.

## 2. Updates

### 2.1 Lineage OTA → **must re-KSU**

**This is the big recurring task.** A Lineage OTA overwrites the inactive slot with fresh Lineage boot.img, then flips slots on reboot. The KSU-patched boot.img on the previously-active slot gets overwritten — after reboot, **both slots hold stock boot and root is gone.** sshd autostart stops working. Phone is just stock Lineage until you re-patch.

**Procedure:**

1. **Install OTA** via Settings → System → Updater (or sideload via recovery per `INSTALLATION.md` if the in-system updater fails). Let it reboot.

1. **After reboot** — stock Lineage boots, but `ssh moon` fails, and KSU Manager shows **"Not installed"**.

1. **Dump the new boot.img via adb root:**
   Ensure "Rooted debugging" is enabled in LineageOS Developer Options, then dump the newly flashed boot partition directly to the internal storage:
    ```
    adb root
    adb shell "dd if=/dev/block/bootdevice/by-name/boot_\$(adb shell getprop ro.boot.slot_suffix) of=/sdcard/Download/boot.img"
    ```

1. **Patch** — open KSU-Next Manager → FAB → *Select and patch a file* → `/sdcard/Download/boot.img`. **KMI: `android12-5.10`** (still correct for marble — don't guess `android13`).

1. **Pull + flash to active slot:**
    ```
    adb pull /sdcard/Download/kernelsu_next_patched_<ts>.img
    adb reboot bootloader
    fastboot flash boot kernelsu_next_patched_<ts>.img
    fastboot reboot
    ```

1. **Verify after boot:**
    - KSU Manager → `Working LKM (GKI2) Version v3.2.0 (33129)`.
    - `ssh moon` works and lands as `user`.
    - `ssh moon cat /var/log/moon-ssh-boot.log` → new invocation, both services rc=0.
    - KSU Manager → SuperUser → **com.termux profile: all capabilities + Global mount namespace** (re-check; upgrades have been seen to reset profiles).

**Escape hatch if the re-patched boot fails to boot:** `fastboot --set-active=<other-slot>` — the inactive slot still has the fresh stock Lineage boot from the OTA. Bootable, but no root.

**Why we only patch the active slot:** the next OTA will overwrite the inactive slot anyway, so mirroring the KSU patch to both slots buys zero OTA persistence. Skip the mirror.

### 2.2 Ubuntu apt upgrade (routine)

```
ssh moon
sudo apt update && sudo apt full-upgrade -y
```

Run monthly-ish. Watch for:
- **openssh-server upgrades** — config in `/etc/ssh/sshd_config.d/10-moon.conf` survives; main `sshd_config` may get overwritten (leave it default).
- **systemd-resolved** getting pulled in as a dep. `start_ubuntu.sh` already handles the dangling `/etc/resolv.conf` symlink on every chroot entry; nothing to do.

### 2.3 Ubuntu 26.04 beta → final LTS (historical — done 2026-04-21)

```
ssh moon "sudo apt update && sudo apt full-upgrade -y"
```

Executed 2026-04-21 07:23 via `apt-get upgrade` (~17 packages: `apt 3.1.16 → 3.2.0`, `libc6 … -2ubuntu1 → -2ubuntu2`, `base-files 14ubuntu5 → ubuntu6`, `rust-coreutils 0.7.0 → 0.8.0`, etc.). `/etc/os-release` now shows `PRETTY_NAME="Ubuntu 26.04 LTS"` and `VERSION_CODENAME=resolute` — no `-beta` suffix. No release-upgrade dance was needed; the `codename beta` → `codename` flip happens in the repo and `apt-get upgrade` picked it up.

User also ran `apt install unminimize` + the bulk `--reinstall` pass it triggers — man pages, docs, locales restored from Ubuntu Base minimization.

Keep this procedure here for the next beta cycle (2028 LTS, etc.).

### 2.4 Tailscale repo pin: `noble` → `resolute` (ready to flip, 2026-04-21)

Currently pinned to `noble` because Tailscale had no `resolute` (26.04) pool at install time. Verified 2026-04-21: `https://pkgs.tailscale.com/stable/ubuntu/dists/resolute/InRelease` returns **HTTP 200** — pool is live. Re-verify before switching (note the `dists/<codename>/InRelease` path; the bare `ubuntu/<codename>/` directory returns 404 even when the pool exists):

```
ssh moon 'curl -sI https://pkgs.tailscale.com/stable/ubuntu/dists/resolute/InRelease | head -1'
# HTTP/2 200 ← ok to flip
```

Flip:

```
ssh moon
sudo sed -i 's|ubuntu noble|ubuntu resolute|g' /etc/apt/sources.list.d/tailscale.list
sudo sed -i 's|# Tailscale packages for ubuntu noble|# Tailscale packages for ubuntu resolute|' /etc/apt/sources.list.d/tailscale.list
sudo apt update && sudo apt install -y --only-upgrade tailscale
```

(Two `sed` calls because the current file has the pool on the `deb …` line and a header comment; update both for consistency.)

Safe anytime — Tailscale binaries are statically-linked Go, so staying on `noble` works indefinitely if the flip is deferred.

### 2.5 KSU-Next Manager upgrade

Check https://github.com/KernelSU-Next/KernelSU-Next/releases for a new APK. Install with `adb install -r <new>.apk` (standard variant, not `spoofed`). Manager updates the userspace side only — the LKM kernel module inside boot.img does not need re-patching unless release notes say the LKM changed (rare).

### 2.6 Boot-hook model migration (applied 2026-06-05, **pending reboot**)

Live box migrated from the old monolithic KSU `service.sh` (which re-ran `ssh_setup.sh` + `tailscale_setup.sh` + gated `agents_start.sh` at boot) to the new one-file-per-hook model (repo refactor `975c049`…`6be3a24`). **Done in-chroot; not yet rebooted — the switch takes effect on the next reboot.**

What changed on the device:
- `/etc/host-hooks/`: installed `10-sshd.hook` + `20-tailscale.hook` (enabled) and `50-agents.hook.disabled`; removed the old `agents.enabled` + `agents_start.sh`.
- `/usr/local/sbin/run-as` installed (new baseline privilege-drop helper).
- `/data/adb/modules/moon-ssh/{service.sh,module.prop}` → **v0.4.0** (generic hook runner), copied via the chroot-escape in `INSTALLATION.md` § "Autostart at boot".
- New files re-staged into Termux home so a rootfs rebuild / Android-side re-provision redeposits the new model.

**Agents are OFF:** `50-agents` ships `.disabled`, so freeloader + hermes will **not** auto-start after reboot (they keep running only until the reboot). To restore: uncomment the freeloader + hermes lines in `/etc/host-hooks/50-agents.hook.disabled`, then `sudo mv` it to `…/50-agents.hook`. Note freeloader's entrypoint is now `freeloader.server:create_default_app` (was `freeloader.frontend.app:create_app`) — verify it serves on `127.0.0.1:8000`.

Verify after the reboot:
```
ssh moon cat /var/log/moon-ssh-boot.log   # "=== hook 10-sshd start ===" + "=== hook 20-tailscale start ==="; final rc=0
ssh moon ss -ltn | grep 2222              # sshd up
ssh moon tailscale status                 # node Connected
```

### 2.7 Android helper consolidation (deployed 2026-06-06)

Repo refactor merged the split `android-lock` / `android-unlock` helpers into a single `android` dispatcher with `lock` / `unlock [--stayon]` subcommands (`scripts/android.sh`, replacing the two deleted scripts), one sudoers stanza, and (originally) one `/usr/local/bin/android` wrapper. Deletes the old `/usr/local/{sbin,bin}/android-{lock,unlock}` binaries on re-run. Behavior unchanged (same keyevents, same `--stayon`, same chroot-escape). **Deployed 2026-06-06** via the in-chroot `termux` path (§1 "In-chroot deploys without adb"). The `/usr/local/bin/android` wrapper this shipped turned out to be broken and was removed in §2.8 below — see there.

### 2.8 reboot/android self-elevation — wrapper-shadow fix (deployed & verified 2026-06-06)

The `/usr/local/bin/{reboot,android}` PATH wrappers (thin `exec sudo …`) were **dead code**: `/usr/local/sbin` precedes `/usr/local/bin` in PATH, so a bare `reboot` / `android` always resolved to the `/usr/local/sbin` script and never reached the wrapper. The sbin script then ran **unprivileged**, and its `chroot /proc/1/root` failed with `chroot: cannot change root directory to '/proc/1/root': no such directory` — because `/proc` is mounted `hidepid=invisible`, which returns ENOENT for `/proc/1` to any non-root caller. Only `sudo reboot` / `sudo android …` worked (they matched the NOPASSWD sbin path and ran as root). `type -a android` was the tell: two hits, `/usr/local/sbin/android` first.

Fix: the sbin scripts now **self-elevate** (`[ "$(id -u)" -ne 0 ] && exec sudo /usr/local/sbin/<cmd> "$@"`), and `ssh_setup.sh` stops installing the bin wrappers and `rm`s them on re-run. `scripts/{android,reboot}.sh` + `ssh_setup.sh` changed; docs updated across `README.md`, `INSTALLATION.md`, and §1 here.

**Deployed & verified 2026-06-06** via the in-chroot `termux` path (§1). For reference, the deploy was:
```
sudo ./scripts/termux.sh cp scripts/android.sh
sudo ./scripts/termux.sh cp scripts/reboot.sh
sudo ./scripts/termux.sh cp scripts/ssh_setup.sh
sudo ./scripts/termux.sh exec sh /data/data/com.termux/files/home/ssh_setup.sh   # bounces sshd at the end
```
Post-deploy verification (from a normal `user` ssh session, no `sudo`): bare `android unlock` / `lock` / `unlock` return rc=0 and drive the screen; `command -v android` shows only `/usr/local/sbin/android` (no `/usr/local/bin/android`).

**Known limitation:** the self-elevation path works from interactive ssh logins but **not** from the Claude agent's own session — despite identical `uid`/groups/`ctx=u:r:ksu:s0`, the agent's elevated-root context makes `system_server` reject the `input`/`wm` binder call with `Failure calling service input: Failed transaction (2147483646)`. The chroot escape itself succeeds (no ENOENT); only the Android service call fails. So `android lock`/`unlock` cannot be driven from in-agent automation — run them from a real ssh session, or via `adb shell su -c 'sh …/android.sh <cmd>'`. Root cause not yet pinned down (suspect a PAM/pty-derived context difference on the elevated process).

### 2.9 reboot stopped disconnecting ssh — SIGHUP regression from §2.8 (**fixed in repo, pending deploy**)

The §2.8 self-elevation (`exec sudo`) inserted a `sudo` layer into `reboot.sh`'s process ancestry, which silently broke its SIGHUP-to-sshd step: it walked a **fixed two hops** up from `$PPID` (correct for `sshd → shell → reboot.sh`), so the extra `sudo` (`sshd → shell → sudo → reboot.sh`) made the HUP land on the login shell instead of sshd. Symptom: `ssh moon reboot` rebooted but the client hung on the socket until the kernel panicked, instead of returning at once. (The §2.8 commit message claimed "the parent walk is the same depth" — that was wrong; the `exec` is in-place but the extra `sudo` process is a real new ancestry hop.)

Fix in `scripts/reboot.sh`: stop counting hops — **climb parents until the first `sshd`** (matches the `sshd` prefix, so OpenSSH ≥9.8's `sshd-session` is covered too). Plus a second path that the old hop-count never handled: an **interactive** login is wrapped in tmux, and the pane shell is a child of the detached tmux *server*, so **sshd is not in the ancestry at all** — for that case `reboot.sh` runs `tmux detach-client` up front (before `exec sudo`, while `$TMUX` still survives the env), which returns the ssh client while the detached pane runs on to fire the reboot. See `docs/LESSONS.md` §4.

**Not yet deployed.** Redeploy via the in-chroot `termux` path (§1), same as §2.8 — stage the new script, then let `ssh_setup.sh` reinstall `/usr/local/sbin/reboot` from the staged copy (it `install`s inside the chroot and bounces sshd at the end):
```
sudo ./scripts/termux.sh cp scripts/reboot.sh
sudo ./scripts/termux.sh exec sh /data/data/com.termux/files/home/ssh_setup.sh
```
Verify: `ssh moon reboot` returns within ~1 s (not after a multi-second socket hang), and the device reboots.

## 3. Troubleshooting

### `ssh moon` times out after a reboot

1. `adb shell cat /data/data/com.termux/files/home/ubuntu/var/log/moon-ssh-boot.log` (chroot's `/var/log/moon-ssh-boot.log` viewed from Android — needed because SSH is down)
    - **Log missing or empty:** module didn't run, OR `service.sh` died before its stage-2 log handoff (in which case the polling preamble is at `/data/local/tmp/moon-ssh-boot.log` — `adb shell cat` that next). KSU Manager → Modules → is `moon-ssh` **enabled**? Did KSU itself boot (Manager shows `Working LKM`)? If not, §2.1 re-KSU or §4 recover.
    - **`ERROR: /data/data/com.termux/files/home never appeared`:** CE storage didn't unlock in time. Read the rest of the preamble at `/data/local/tmp/moon-ssh-boot.log`. Did a screen lock PIN get re-enabled? Remove it. Or bump the poll timeout in `service.sh` from 10s → 30s.
    - **`hook 10-sshd.hook exited rc=<nonzero>`:** the start-only sshd hook failed. `rc=1` with `sshd not provisioned` means `ssh_setup.sh` never ran on this rootfs — run it: `adb shell su -c 'sh /data/data/com.termux/files/home/ssh_setup.sh'`. Otherwise read the hook's stderr in the boot log. (Hooks are surfaced in lexical order, so `10-sshd`'s rc wins over `20-tailscale`/`50-agents`.)

1. If the log shows both rc=0 but SSH still fails — check LAN: is the phone still at `MOON_LAN_HOST`? Router DHCP reservation might have drifted. Use `tailscale ssh root@moon` (MagicDNS) in the meantime.

### `ssh moon` times out despite `sshd` process appearing in `ps`

This indicates a **Ghost Process** — the daemon is alive but has lost its listener socket (often due to ungraceful client disconnects or network hangs) or is stuck in a syscall.

1. **Verify the listener:** From Android, check if anyone is actually listening on 2222:
    ```bash
    adb shell su -c 'sh /data/data/com.termux/files/home/start_ubuntu.sh "ss -tulpn | grep 2222"'
    ```
    If `ps` shows `sshd` but `ss` is empty, the process is a ghost.

1. **Forceful cleanup:** Standard `pkill` (SIGTERM) might be ignored if the process is stuck. Use SIGKILL:
    ```bash
    adb shell su -c 'sh /data/data/com.termux/files/home/start_ubuntu.sh "pkill -9 sshd"'
    ```

1. **Restart:**
    ```bash
    adb shell su -c 'sh /data/data/com.termux/files/home/start_ubuntu.sh "/usr/sbin/sshd -p 2222"'
    ```

1. **Hardening:** Ensure `ClientAliveInterval 30` and `ClientAliveCountMax 4` are set in `/etc/ssh/sshd_config.d/10-moon.conf` (applied 2026-05-09) to auto-terminate dead sessions after 2 minutes.

### Tailscale unreachable but LAN SSH works

1. `ssh moon` (LAN), then `tail -n 50 /var/log/tailscaled.log`.
1. `/usr/bin/tailscale --socket=/var/run/tailscale/tailscaled.sock status` — logged in? DERP connected?
1. If logged out: `tailscale --socket=… up --ssh --hostname=moon` → visit auth URL on Mac.

### Permission denied entering chroot (`chroot: Operation not permitted`)

KSU profile for Termux has regressed. Re-grant: KSU Manager → SuperUser → com.termux → **Capabilities: ALL**, **Mount namespace: Global**. Default-granted profiles leak shell-UID with zero caps, which fails `chroot()` silently.

### Ubuntu tree unreadable from root (ENOENT despite files being there)

Stale chroot mounts across Android's three app-data mirror paths. The archived `scripts/archive/cleanup_mounts.sh` lazy-unmounts all three trees — read it for the exact paths/logic.

Do not invoke blind: the current `start_ubuntu.sh` no longer rbinds `/dev`, so a stuck-mount scenario on the active stack is unexpected. Running the archived script against a live chroot risks propagating the unmount up and wiping host binderfs (the footgun it was built for, pre-2026-04-20). Diagnose the source of the stuck mount first, then apply the narrowest `umount -l` that covers it.

### SSH throughput ~50% when phone screen off

**This shouldn't normally manifest** — *Stay awake while charging* (see §1 Device settings) keeps the screen on whenever the phone is plugged in, which is always. If you see the throttle anyway, check charging first (bad cable / loose port / PD renegotiation glitch). Once screen-off is confirmed, the drop is kernel-side throttling — the sshd is not an app, so battery whitelist / foreground service tricks don't apply. Mitigations, biggest first:

1. Pin the CPU governor to `performance` on Android side (not in chroot):
    ```
    adb shell su -c 'for f in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do echo performance > $f; done'
    ```
1. Hold a wake lock while SSH is active: `adb shell svc power stayon true` (burns battery; fine for always-plugged).
1. Audit `/sys/module/msm_performance/parameters/` and `/sys/devices/system/cpu/cpu*/cpufreq/scaling_max_freq` for vendor-imposed screen-off caps.
1. If numbers still halve — suspect thermal or a userspace freq daemon (Qualcomm mpdecision-equivalent). Chase from there.

For ad-hoc screen-state control (e.g. the phone fell asleep and you need it awake right now without physical access), use `android lock` / `android unlock` (source: `scripts/android.sh`) — see §1 "Manual screen lock / unlock".

Not an app-lifecycle problem — don't waste time on foreground-service / notification-sticky fixes.

### CPU max-freq cap is intentional (`scaling_max_freq` < hardware max)

Since 2026-06-15, `60-thermal.hook` deliberately caps the Big/Prime clusters below their hardware
max (`scaling_max_freq` = **2227200 / 2592000** kHz vs hw 2496000 / 2918400) as a sustained-load
thermal backstop after the crash-loop reboots — full rationale in `docs/LESSONS.md` §4 and
`§3 "SSH throughput"` mitigation 3 above. **This is not a vendor screen-off throttle to remove.**
If the throughput audit shows `scaling_max_freq < cpuinfo_max_freq`, that is the cap working.

- **Retune:** edit `/etc/moon-thermal.conf` (`CAP_BIG_KHZ` / `CAP_PRIME_KHZ`; value must be a real
  `scaling_available_frequencies` rung, empty = leave at hardware max), then reboot or re-run
  `adb shell su -c 'sh /data/data/com.termux/files/home/thermal_setup.sh'`. Don't hand-write the
  sysfs node — the hook re-applies the configured value at every boot.
- **Governor interplay:** pinning `performance` (mitigation 1) is compatible — it runs the CPU *at*
  `scaling_max_freq`, which is the cap.
- **Evidence:** `/var/log/moon-thermal.log` carries the temp/freq history; the `p4max`/`p7max`
  columns reveal if the vendor stack ever rewrites the cap (it didn't, in the 2026-06-15 soak).
- **Disable entirely:** `sudo mv /etc/host-hooks/60-thermal.hook{,.disabled}` and reboot (or set both
  caps empty in the config). `pkill -f moon-thermal-monitor` stops the logger.

### `adb shell su` returns "not found"

**Expected.** KSU-Next has no system-wide `su` binary in PATH; root is granted per-app via Manager. Use `adb shell su -c '<cmd>'` which goes through the KSU shell profile. Enable **Shell (uid=2000)** in Manager → SuperUser if not already granted — with **ALL caps** and **Global mount namespace**, same as the Termux profile.

### `/sys/module/kernelsu/version` returns ENOENT but KSU works

Expected in KSU-Next v3.2.0 LKM mode. Don't verify root through those sysfs paths — they're not world-readable. The KSU Manager's status banner (`Working LKM (GKI2) Version …`) is the source of truth.

### DNS dies after `ssh_setup.sh` (resolv.conf `0600`)

Symptom: every hostname stops resolving (`Could not resolve host …`) although `tailscale status` shows the node up and `ip route` shows `wlan0` with an address — i.e. the network is fine, only DNS is dead. Check `ls -l /etc/resolv.conf`: if it is `-rw-------` (root-only), the non-root resolver can't read it. Cause: `start_ubuntu.sh` does `rm -f` then `cat >` on `/etc/resolv.conf` (to dodge a systemd-resolved dangling symlink), so it is recreated under the caller's umask — and `ssh_setup.sh` re-enters the chroot under root's `umask 077`, landing the fresh file at `0600`. Fix on the box: `sudo chmod 644 /etc/resolv.conf`. Permanent fix (2026-06-06): `start_ubuntu.sh` now `chmod 0644`s resolv.conf/hosts/hostname after writing — deploy the updated `start_ubuntu.sh` (`sudo ./scripts/termux.sh cp scripts/start_ubuntu.sh`) so it sticks across reboots.

## 4. Recovery

### Bootloop after KSU re-patch

1. `adb reboot bootloader` (during the bootloop, hold vol-down + power).
1. `fastboot --set-active=<other-slot>` — the inactive slot is stock (either pre-OTA Lineage KSU-patched, or fresh Lineage from the OTA, depending on when the bootloop started).
1. `fastboot reboot`. Phone should boot the other slot.
1. Redo §2.1 carefully — KMI was probably wrong (marble needs `android12-5.10`, **not** `android13`).

### Bootloop after OTA (before you've re-KSU'd)

1. `fastboot --set-active=<previous-slot>` rolls back to pre-OTA Lineage. Old kernel, old system, but KSU still present and sshd autostart still works.
1. Diagnose why the OTA won't boot before retrying.

### Unrecoverable bootloop (neither slot boots)

Reflash Lineage from scratch per [`INSTALLATION.md`](INSTALLATION.md). User data in `/data` is preserved by fastboot partition flashes (it lives in the userdata partition, not `boot_a/b`), so the chroot, KSU module, and Tailscale state survive — you lose KSU itself (need to re-patch) but not the rootfs.

### Chroot corrupt (Ubuntu tree broken)

Termux sandbox is fine (separate dir). Rebuild the chroot:

```
adb shell su -c 'rm -rf /data/data/com.termux/files/home/ubuntu'
adb push roms/ubuntu/ubuntu-base-26.04-beta-base-arm64.tar.gz /sdcard/Download/
adb shell su -c 'sh /data/data/com.termux/files/home/extract.sh'
adb shell su -c 'sh /data/data/com.termux/files/home/apt_bootstrap.sh'
adb shell su -c 'sh /data/data/com.termux/files/home/ssh_setup.sh'
adb shell su -c 'sh /data/data/com.termux/files/home/tailscale_setup.sh'
```

Tailscale will re-auth because `/var/lib/tailscale/tailscaled.state` was in the old chroot tree. Either restore from backup (§5) or `tailscale up --ssh --hostname=moon` fresh.

**`user` account re-provisioning is automatic.** `ssh_setup.sh` (invoked in the rebuild sequence above) idempotently creates the account, home, and authorized_keys with a locked password. To re-enable sudo after rebuild:

```
adb shell su -c '/data/data/com.termux/files/home/start_ubuntu.sh'
passwd user                         # set and remember, then exit
```

**Sudo prerequisite.** The chroot root must be bind-mounted with `suid` or sudo will fail with `sudo: sudo must be owned by uid 0 and have the setuid bit set` — Android's `/data` is `nosuid`. `start_ubuntu.sh` does this automatically on every entry (bind-remount block near the top). Verify after rebuild with `grep "/data/data/com.termux/files/home/ubuntu " /proc/self/mountinfo` — the flags should read `rw,noatime` (no `nosuid`).

### Lost Tailscale auth (but chroot intact)

```
ssh moon    # via LAN, as user
sudo rm /var/lib/tailscale/tailscaled.state
# restart tailscaled via the setup script from outside
exit
adb shell su -c 'sh /data/data/com.termux/files/home/tailscale_setup.sh'
# then re-auth:
ssh moon
sudo tailscale --socket=/var/run/tailscale/tailscaled.sock up --ssh --hostname=moon
```

Approve the new auth URL on Mac. Delete the old `moon` machine in the admin console or leave it as a ghost.

## 5. Backups

Full rootfs backup is unnecessary — the rootfs is reproducible from the upstream Ubuntu Base tarball + apt history. Back up the irreplaceable state:

```
mkdir -p ~/backup/marble-server/$(date +%F)
cd ~/backup/marble-server/$(date +%F)

# 1. Tailscale identity — avoids re-auth on rebuild
adb exec-out su -c 'cat /data/data/com.termux/files/home/ubuntu/var/lib/tailscale/tailscaled.state' \
  > tailscaled.state

# 2. SSH host keys — avoids StrictHostKeyChecking warnings after rebuild
adb exec-out su -c 'cd /data/data/com.termux/files/home/ubuntu/etc/ssh && tar -cf - ssh_host_*' \
  > ssh_host_keys.tar

# 3. Drifted on-device scripts + authorized_keys (compare against repo `scripts/` and `config/authorized_keys`)
adb exec-out su -c 'cd /data/data/com.termux/files/home && tar -cf - *.sh authorized_keys' \
  > termux-home-scripts.tar
```

Re-run after any script/key drift or post a `tailscale up`. The live `authorized_keys` file is intentionally gitignored; this grab is for private backup and drift checking.

**Not backed up:** the Ubuntu rootfs (recreate from tarball), apt package state (`apt-mark showmanual` inside chroot documents what was installed — consider dumping this to the repo when the list stabilizes).
