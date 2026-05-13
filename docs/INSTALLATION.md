# Marble Server Installation Guide

This document consolidates the end-to-end installation process.

---

# Install LineageOS 23.2 on Xiaomi Poco F5 Global (marble, variant1)

- **Device:** Xiaomi Poco F5 Global (`marble`, model `23049PCD8G`)
- **Android Version:** 16 (AOSP-based, delivered via Lineage 23.2)
- **LineageOS Version:** 23.2
- **Build Date:** Tue Apr 14 2026
- **Type:** nightly (signed)
- **Size:** 1.8 GB
- **Variant:** variant1 (POCO F5 Global — Redmi Note 12 Turbo is variant2, separate guide)
- **Official guide:** https://wiki.lineageos.org/devices/marble/install/variant1/

## Prerequisites

1. Bootloader unlocked (already done on this device).
2. USB debugging enabled on last boot.
3. **Firmware must be Android 15** (modem / tz / xbl / abl partitions from stock HyperOS/MIUI A15). Being on another custom ROM does **not** satisfy this — verify before flashing. If unsure, flash stock HyperOS A15 marble firmware first.
4. `adb` and `fastboot` installed on the host.

## Files (all in `roms/lineage23/`)

- `boot.img` (201 MB)
- `dtbo.img` (25 MB)
- `vendor_boot.img` (101 MB)
- `recovery.img` (105 MB)
- `lineage-23.2-20260414-nightly-marble-signed.zip` (1.8 GB)

Staged but **not used by this guide** (reserve for verity/super recovery):

- `vbmeta.img` (8 KB)
- `super_empty.img` (5 KB)

## Installation Steps

### 1. Flash additional partitions

With the device in bootloader (`fastboot devices` shows it):

```
fastboot flash boot boot.img
fastboot flash dtbo dtbo.img
fastboot flash vendor_boot vendor_boot.img
fastboot --disable-verity --disable-verification flash vbmeta vbmeta.img
fastboot reboot bootloader
```

Partition names are **unslotted** — these flash the currently-active slot only. The OTA installer syncs the opposite slot on first install.

**Why `--disable-verity --disable-verification` on vbmeta:** this patches the AVB header flags so that dm-verity and vbmeta verification are relaxed. Required because we'll replace `boot.img` with a KSU-Next-patched version after first boot — an unpatched vbmeta would refuse the modified boot. Additive to the official Lineage variant1 wiki steps, which don't cover rooted setups.

### 2. Flash Lineage Recovery

```
fastboot flash recovery recovery.img
fastboot reboot recovery
```

On reboot, the screen must show the **LineageOS logo**. If it shows a POCO/MIUI recovery or something else, the wrong recovery partition was written — restart from step 1.

### 3. Format data and sideload the OTA

In Lineage recovery:

1. **Factory Reset → Format data / factory reset** → confirm.
2. Return to the main menu.
3. **Apply update → Apply from ADB**.
4. On the host:

   ```
   adb -d sideload roms/lineage23/lineage-23.2-20260414-nightly-marble-signed.zip
   ```

   Normal success: `Total xfer: 1.00x`. Known-benign variants: output stops at ~47% with `adb: failed to read command: Success` / `No error` / `Undefined error: 0` — the install still completed.

   **Do not reboot to system yet** if you want to install add-ons (e.g. GApps). Add-ons must go in before first boot.

### 4. (Optional) Install add-ons

Only if you want GApps or similar — this project does **not** need them. Skip to step 5.

If needed: **Apply update → Apply from ADB** again, then `adb -d sideload /path/to/addon.zip`. Accept `Signature verification failed` with "Yes" — add-ons aren't signed by Lineage's key.

### 5. First boot

Back arrow → **Reboot system now**. First boot ≤ 15 minutes. Walk the Lineage setup wizard, then enable Developer Options + USB debugging.

## Post-install: root (Path A — LKM via KSU-Next v3.2.0)

1. Install **KernelSU-Next Manager** APK on the running Lineage system. Source: `https://github.com/KernelSU-Next/KernelSU-Next/releases/latest`. Pinned working build: `KernelSU_Next_v3.2.0_33129-release.apk` (10 MB, SHA256 `96c2bbbf1b973461fe82dd1ed17f89deb86a6a5a9d7c4cf079bd32091131ef57`). Use the standard (non-`spoofed`) variant — no need for Play Integrity bypass on this headless device. Sideload via `adb install` or browser → install from unknown sources.
2. Push stock boot to phone (input for the patcher): `adb push roms/lineage23/boot.img /sdcard/Download/`.
3. In KernelSU-Next Manager: tap the FAB → **Select and patch a file** → pick `Download/boot.img`. App prompts for **KMI** (kernel module ABI). For marble pick **`android12-5.10`** — *not* `android13-5.10`. POCO F5 launched on Android 13 userspace but the GKI base is `android12-5.10` (per `ro.vendor.api_level=32`). Picking `android13-5.10` produces a patched boot that flashes cleanly but the LKM fails to load — Manager status reads "Not installed" after reboot. Confirmed wrong on this device 2026-04-19.
4. Pull the patched image: `adb pull /sdcard/Download/kernelsu_next_patched_<timestamp>.img`.
5. Reboot to bootloader and flash to active slot:
   ```
   adb reboot bootloader
   fastboot flash boot kernelsu_next_patched_<timestamp>.img
   fastboot reboot
   ```
   This flashes the currently-active slot only. The other slot keeps stock Lineage boot — useful as an escape hatch via `fastboot --set-active=<other>`. Lineage OTAs always overwrite the inactive slot, so don't bother mirroring the patch unless you intend never to OTA.
6. Open KernelSU-Next Manager on boot — status banner should read **`Working LKM (GKI2) Version v3.2.0 (33129)`**. Do **not** verify by checking `/sys/module/kernelsu/version` from `adb shell` — those paths are not exposed to non-root in v3.2.0 LKM mode and will return ENOENT even when KSU is loaded. The Manager's status string is the source of truth.
7. Verify root inside Termux (after section 2 setup): KSU-Next Manager → **SuperUser** → enable Termux → in Termux run `su` → expect Manager popup asking to grant root → `#` prompt. There is no system-wide `su` binary in PATH from `adb shell` — that's by design for KSU-Next, not a failure.

**Do not** flash any of the `Evo-*-KSU-Next-susfs.zip` files in `roms/15/` or `roms/KSU/` — they are EvoX-specific and will not boot on Lineage.


---

# Phase 2 — Termux + Ubuntu 26.04 chroot

Deploy the Ubuntu rootfs directly onto `/data` (no loopback image) and enter it via `chroot` from Termux. Prerequisite: phase 1 complete — device is booted on Lineage 23.2 with KSU-Next manager showing `Working LKM (GKI2)`.

## 1. Install F-Droid + Termux

F-Droid first, Termux from F-Droid (not `adb install` of Termux upstream).

**Why:** F-Droid builds Termux from source with its own signing key — a distinct supply chain from upstream GitHub — and gives auto-updates for Termux and any future FOSS companions (termux-api, etc.). The one-time cost is one extra app on device.

```
adb install roms/apks/F-Droid.apk
```

F-Droid APK verified against its master signing key (`37D2C98789D8311948394E3E41E7044E1DBA2E89`) before install — fetched from Ubuntu's keyserver (`keyserver.ubuntu.com`) because `hkps://` keyservers failed with `伺服器故障` on this network. Then open F-Droid, search **Termux**, install.

> F-Droid shows **"built for an older version of Android"** on Termux. That is expected — Termux pins `targetSdk=28` to preserve `exec()` from `$HOME`. It is not a defect. Consequence: Termux auto-updates don't fire silently; tap in F-Droid to update.

## 2. Verify root in Termux

KSU-Next Manager → SuperUser → authorize **com.termux** (Global mount namespace, all capabilities — see phase 1 "KSU profile requirements").

Open Termux, run `su`. KSU Manager should pop up a grant prompt the first time. Expect:

```
$ su
# id
uid=0(root) gid=0(root) ...
```

If `su` errors, re-check the KSU profile. Default-granted profiles leak shell UID with zero capabilities, which fails `chroot()` silently further down.

## 3. Download the Ubuntu rootfs

Ubuntu Base 26.04 ARM64 — currently beta; roll to final LTS post-2026-04-23 via `apt full-upgrade`.

```
curl -o roms/ubuntu/ubuntu-base-26.04-beta-base-arm64.tar.gz \
  https://cdimage.ubuntu.com/ubuntu-base/releases/26.04/beta/ubuntu-base-26.04-beta-base-arm64.tar.gz
curl -o scripts/SHA256SUMS     https://cdimage.ubuntu.com/ubuntu-base/releases/26.04/beta/SHA256SUMS
curl -o scripts/SHA256SUMS.gpg https://cdimage.ubuntu.com/ubuntu-base/releases/26.04/beta/SHA256SUMS.gpg
```

Dual-verify: SHA256 matches `SHA256SUMS`, and `SHA256SUMS` is GPG-signed by the Ubuntu CD Image Automatic Signing Key `843938DF228D22F7B3742BC0D94AA3F0EFE21092`.

```
gpg --keyserver keyserver.ubuntu.com --recv-keys 843938DF228D22F7B3742BC0D94AA3F0EFE21092
gpg --verify scripts/SHA256SUMS.gpg scripts/SHA256SUMS
( cd roms/ubuntu && shasum -a 256 -c <(grep 'base-arm64.tar.gz' ../../scripts/SHA256SUMS) )
```

## 4. Push rootfs + scripts to device

```
adb push roms/ubuntu/ubuntu-base-26.04-beta-base-arm64.tar.gz /sdcard/Download/
adb push scripts/start_ubuntu.sh scripts/extract.sh scripts/apt_bootstrap.sh \
         /data/data/com.termux/files/home/
```

Re-verify SHA256 on-device (`sha256sum` in Termux) — transfer corruption is rare but cheap to rule out.

## 5. Extract the rootfs

```
adb shell su -c 'sh /data/data/com.termux/files/home/extract.sh'
```

`extract.sh` extracts to `/data/data/com.termux/files/home/ubuntu` with `tar --numeric-owner -xpzf` — preserves perms and avoids remapping uids against Android's android.uid.* database.

Expected end state: 17 top-level FHS dirs, `usr/bin/` has ~391 entries, total ~120 MB.

## 6. Enter the chroot

```
adb shell su -c 'sh /data/data/com.termux/files/home/start_ubuntu.sh'
```

### What `start_ubuntu.sh` does

- **tmpfs at `/dev`** — *not* `--rbind /dev` from the host. An rbind replicates nested kernel filesystems (binderfs, kgsl) into the chroot; a later lazy umount against that rbind propagates up and can wipe the host's binderfs mount, killing every Android app until reboot. Incident logged 2026-04-20.
- **Narrow `/dev` leaves** — `mknod` char devices for `null zero full random urandom tty` at their canonical major/minor; devpts instance at `/dev/pts` with its own `ptmx`; tmpfs at `/dev/shm`; symlink `/dev/ptmx → pts/ptmx`.
- **`/proc` and `/sys`** are rbind'd (read-only access patterns, no nested mounts we need to protect against).
- **`/sdcard` bind-mount** for file exchange with Android.
- **DNS** — writes `/etc/resolv.conf` with `1.1.1.1` and `8.8.8.8` on every entry. `rm -f` first because `apt install openssh-server` pulls `systemd-resolved` as a dep, which leaves `/etc/resolv.conf` as a dangling symlink (we don't run systemd, so the target `/run/systemd/resolve/stub-resolv.conf` doesn't exist).
- **`/etc/hosts`, `/etc/hostname`** — `moon` on both IPv4 and IPv6 loopback.
- **`chroot` with `env -i`** — purges Android's `PATH` and replaces with Ubuntu's standard PATH.

Modes:

```
# Interactive login shell
su -c /data/data/com.termux/files/home/start_ubuntu.sh

# One-shot command
su -c '/data/data/com.termux/files/home/start_ubuntu.sh apt-get update'
```

### Verify entry

Inside the chroot:

```
# apt --version   # 3.1.16 (arm64)
# uname -a        # GNU/Linux
# getent hosts archive.ubuntu.com   # resolves over IPv6
```

## 7. Bootstrap base packages

From Android (not inside the chroot):

```
adb shell su -c 'sh /data/data/com.termux/files/home/apt_bootstrap.sh'
```

`apt_bootstrap.sh` runs `apt-get update && apt-get install -y openssh-server ca-certificates less vim-tiny iproute2 iputils-ping`.

## Gotchas (keep handy)

- **KSU profile for Termux must be Global mount namespace, not Inherited.** Inherited uses the shell's namespace, which hides `/data/data/com.termux/files/` entirely.
- **`chroot` fails with "Permission denied" despite uid=0** → KSU profile has default zero-caps. Check ALL capabilities in the KSU profile.
- **Residual mounts make Ubuntu tree unreadable.** A failed chroot entry propagates mounts to Android's three mirror paths (`/data/data/...`, `/data_mirror/data_ce/null/0/...`, `/data/user/0/...`). The archived `scripts/archive/cleanup_mounts.sh` lazy-unmounts them all — quarantined because `start_ubuntu.sh` no longer rbinds `/dev` and running it against a live chroot can propagate and vaporize the host's binderfs mount. Read for reference; don't invoke blind.


---

# Phase 3 — OpenSSH + autostart at boot

Stand up OpenSSH inside the chroot on port 2222, pin the device to a LAN IP, wire autostart through a KSU-Next module. End state: `ssh moon` from Mac lands as the non-root `user` after a cold boot, no manual intervention.

Prerequisite: phase 2 complete — `openssh-server` installed in the chroot by `apt_bootstrap.sh`.

## 1. Configure and start sshd

From Android:

```
adb shell su -c 'sh /data/data/com.termux/files/home/ssh_setup.sh'
```

`ssh_setup.sh` opens a chroot session via heredoc, then:

1. Stages the gitignored live `config/authorized_keys` file into `/home/user/.ssh/authorized_keys`. Start from `config/authorized_keys.example`, add local public keys, and re-push after key rotation — never bake keys into the script.
1. Writes `/etc/ssh/sshd_config.d/10-moon.conf`: `Port 2222`, `ListenAddress 0.0.0.0`, `PermitRootLogin no`, `PasswordAuthentication no`, `PubkeyAuthentication yes`. OpenSSH is pubkey-only and non-root; root administration goes through `sudo`, `adb shell su`, or Tailscale identity SSH where configured.
1. Installs `/usr/local/sbin/reboot` from the repo-tracked `scripts/reboot.sh`. Shadows Ubuntu's systemd-wrapper `/sbin/reboot` — in-chroot `reboot(2)` works (we have `CAP_SYS_BOOT`) but bypasses Android init's graceful-shutdown sequence, and SSH hangs because the kernel panics before sshd can close the TCP socket. The script hops out to Android's init via `/proc/1/root`, schedules toybox `reboot` detached, then SIGHUPs the per-session sshd so the SSH client returns within tens of ms. Lives under `/usr/local/sbin` which dpkg/apt never touch, so it survives package upgrades. Earlier revisions kept two reboot scripts (a slow stdio-EOF shim here plus a separate fast SIGHUP variant at `/root/reboot.sh`); the current script collapses them — `ssh_setup.sh` removes the stale `/root/reboot.sh` and `/etc/sudoers.d/50-reboot` on re-run.
1. Installs `/usr/local/sbin/{android-lock,android-unlock}` from the repo-tracked `scripts/android-{lock,unlock}.sh`. Same chroot-escape pattern as `reboot` — they reach `/system/bin/input` / `wm` / `svc` via `chroot /proc/1/root`, so they need `CAP_SYS_CHROOT` and live in root-only territory.
1. Writes `/etc/sudoers.d/50-moon-helpers` granting `user` NOPASSWD on `/usr/local/sbin/{reboot,android-lock,android-unlock}` (three explicit-path stanzas, no globbing), and drops thin `exec sudo` wrappers at `/usr/local/bin/{reboot,android-lock,android-unlock}`. The wrappers put the commands in default PATH everywhere — `ssh moon-user reboot`, bare `reboot` in an interactive shell, scripted invocations, all work without aliases or PATH gymnastics.
1. Kills any prior `/usr/sbin/sshd` and relaunches it. sshd daemonizes; the `nohup` is implicit via the heredoc exec model.

Expected output ends with `ss`/`netstat` showing `:2222` in `LISTEN` and `ls /home/user/.ssh/` showing `authorized_keys` mode 600.

> **Why daemonize inside the chroot heredoc rather than run under an init?** No systemd or runit lives in the chroot — we kept it bare. sshd's own fork-to-background is enough, and it reparents to init (PID 1 is Android's init since the chroot shares the PID namespace). Future re-entries don't orphan it.

## 2. LAN wiring

Router DHCP reservation pins the phone's MAC to the LAN IP recorded as `MOON_LAN_HOST` in `config/moon.env`. Mac's `~/.ssh/config`:

```
Host moon
    HostName <MOON_LAN_HOST>
    Port 2222
    User user
    IdentityFile <MOON_SSH_IDENTITY_FILE>
    IdentitiesOnly yes
```

Keypair path is `MOON_SSH_IDENTITY_FILE` in the local config. First connect from Mac:

```
ssh moon
```

## 3. Autostart at boot (KSU-Next module)

File layout on device: `/data/adb/modules/moon-ssh/{module.prop, service.sh}`. Source-of-truth copy: `scripts/ksu-moon-ssh/`.

Install (from a workstation with adb):

```
adb push scripts/ssh_setup.sh scripts/tailscale_setup.sh \
         config/authorized_keys scripts/reboot.sh \
         scripts/android-lock.sh scripts/android-unlock.sh \
         /data/data/com.termux/files/home/
adb shell su -c 'mkdir -p /data/adb/modules/moon-ssh'
adb push scripts/ksu-moon-ssh/module.prop scripts/ksu-moon-ssh/service.sh \
         /data/adb/modules/moon-ssh/
adb shell su -c 'chmod 755 /data/adb/modules/moon-ssh/service.sh'
```

**Update from inside the chroot (no adb)** — for ongoing edits to `module.prop` / `service.sh` once the module is already installed. PID 1's root is the Android FS, so a chroot-escape reaches `/data/adb/modules/`:

```
sudo chroot /proc/1/root /system/bin/sh -c '
  SRC=/data/data/com.termux/files/home/ubuntu/home/user/marble-server/scripts/ksu-moon-ssh
  DST=/data/adb/modules/moon-ssh
  cp "$SRC/module.prop" "$DST/" && cp "$SRC/service.sh" "$DST/" && chmod 755 "$DST/service.sh"
'
```

KSU Manager picks the module up on next boot (or toggle in the Modules UI).

### What `service.sh` does at `late_start service`

1. Redirects its own stdout/stderr to `$UBUNTU/var/log/moon-ssh-boot.log` (= `/var/log/moon-ssh-boot.log` in-chroot) for post-mortem. Lives inside the rootfs so it can be tailed from the chroot after `ssh moon`.
1. Sets the kernel hostname via `hostname moon` — Android init defaults to `localhost`, and since the chroot shares the UTS namespace this single call covers both.
1. Polls up to 10 seconds for `/data/data/com.termux/files/home` to appear (CE-storage decryption completes ~9 s into `late_start service` on this build).
1. Invokes `ssh_setup.sh` (new chroot session inside), captures rc.
1. Invokes `tailscale_setup.sh` (another new chroot session), captures rc.
1. Exits with ssh's rc if that failed, else tailscale's rc. sshd-down is treated as more critical.

### CE storage prerequisite

Screen lock PIN was **removed** on 2026-04-20. Without it, CE-protected app data (`/data/data/com.termux/...`) stays encrypted past `late_start service` timing and the module would fail. Re-enabling a screen lock on this device breaks autostart.

### Cold-boot verification

From Mac:

```
ssh moon                                  # should connect as `user` within ~12 s of power-on
ssh moon cat /var/log/moon-ssh-boot.log   # audit trail (in-chroot path)
```

Log should show both `ssh_setup.sh exited rc=0` and `tailscale_setup.sh exited rc=0`.

## Why a KSU module, not `/data/adb/service.d/`

1. Shows up in KSU Manager's Modules UI with a visible toggle.
1. Survives Manager upgrades.
1. Has a clean uninstall path (delete the module directory, or disable in UI).
1. `service.d/` doesn't exist by default in KSU-Next and requires manual creation for every new install.

## Gotcha: service.d timing margin

`service.sh` polls 10 seconds for the Termux app-data dir. The observed CE-populate window is ~9 s — 1 s of margin. If a future ROM/kernel update slows CE population, bump to 30 s. Symptom will be `ERROR: /data/data/com.termux/files/home never appeared` in the boot log.

## Post-install: non-root `user` account

Adds `user` inside the chroot as a work account — system files (`/etc`, `/usr`, `/var`) stay protected from user-level `rm -rf` typos; experimental tooling (`node_modules`, Python venvs, random git checkouts) stays isolated in `/home/user`. Root access is still one `sudo` away; this is oops-protection, not a sandbox.

### Prerequisite: sudo needs suid on the chroot root

Android mounts `/data` as `nosuid,nodev,noatime` by security policy. The chroot lives on `/data`, so setuid binaries (sudo-rs, `su`, `ping`, `passwd`) are inert despite having the setuid bit set — `sudo` errors with `sudo: sudo must be owned by uid 0 and have the setuid bit set`, which is misleading (the bit *is* set; the mount flag is the blocker).

`start_ubuntu.sh` handles this automatically on every entry: it bind-mounts `$UBUNTU` onto itself and remounts the bind with `suid,exec,dev`. Linux 4.5+ allows relaxing these flags on a bind-remount without touching the underlying `/data` mount; shared-subtree propagation carries mount events, not flag changes, so Android's `/data` stays `nosuid` globally.

Verify from inside the chroot:

```
grep "/data/data/com.termux/files/home/ubuntu " /proc/self/mountinfo
# Expect: rw,noatime  (not rw,nosuid,nodev,noatime)
```

**Gotcha for manual `mount` calls inside the chroot:** util-linux `mount` can't target `/` directly because `/proc/self/mounts` doesn't list the chroot's own root mount. Use `/proc/1/root/data/data/com.termux/files/home/ubuntu` (init's view) as the mount target — it reaches out of the chroot via the pseudo-symlink and util-linux resolves it correctly. From Android side pre-chroot (which is how `start_ubuntu.sh` runs), no such workaround is needed.

### Create the user

`ssh_setup.sh` creates the account idempotently — account + home + `.ssh/authorized_keys` + `sudo` group membership. The password is locked on creation so pubkey SSH works immediately without baking a hash into the repo. To enable `sudo`, set the password one-shot from a root path after provisioning:

```
adb shell su -c '/data/data/com.termux/files/home/start_ubuntu.sh'
passwd user                         # set and remember the password, then exit
```

Root stays locked (Ubuntu default — do **not** `passwd root`). Privilege escalation goes through `sudo`, which prompts for `user`'s password.

### Mac `~/.ssh/config`

Optional tailnet alias using the same non-root OpenSSH account:

```
Host moon-user
    HostName <MOON_TAILNET_HOST>
    Port 2222
    User user
    IdentityFile <MOON_SSH_IDENTITY_FILE>
    IdentitiesOnly yes
```

Test: `ssh moon-user` (pubkey-only, reuses the existing Mac key). Tailscale identity SSH also works: `tailscale ssh user@moon`.

### Durability gotcha

`ssh_setup.sh` re-provisions account structure (`/etc/passwd` entry, home, `.ssh/authorized_keys`, `sudo` group) on every invocation. The **password hash** (in `/etc/shadow`) is not — it's locked on account creation and left alone thereafter. On chroot rebuild the account comes back automatically, but `sudo` is inert until you set `passwd user` once from a root path.

### tmux auto-start

Interactive SSH sessions automatically attach to an existing `ssh_`-prefixed tmux session or create a new one. This ensures your shell survives connection drops. It explicitly ignores background AI agents (like `openclaw` or `hermes`) which do not use the `ssh_` prefix.


---

# Phase 3.5 — Tailscale for off-LAN access

Phase 3's OpenSSH only works on the home LAN (`MOON_LAN_HOST:2222`). This phase adds Tailscale so `ssh moon-ts` — or Tailscale identity SSH such as `tailscale ssh user@moon` / `tailscale ssh root@moon` — works from any network, including cellular, without port-forwarding or a public IP.

Prerequisite: phase 3 complete — OpenSSH autostarts at boot, `ssh moon` works on LAN.

## Why Tailscale over the alternatives

| Option | Verdict |
| :--- | :--- |
| DDNS + home port-forward | Dead on arrival. Home ISP and mobile carrier are both likely CGNAT; no stable inbound anywhere. |
| Self-hosted WireGuard | Needs a $5/mo relay VPS. No gain over Tailscale's free tier for this use case. |
| ZeroTier | Comparable to Tailscale. Loses on Tailscale SSH (identity-based auth = no private keys on iPhone) + MagicDNS for the iPhone client story. |
| Cloudflare Tunnel | HTTP-oriented. SSH needs the `cloudflared access` wrapper on every client. |
| Tailscale | NAT-piercing via DERP, roams across networks, native macOS/iOS clients, identity SSH. **Pick.** |

## Decisions locked in

| Knob | Setting | Why |
| :--- | :--- | :--- |
| Account | Tailnet account/domain recorded in `config/moon.env` | Fresh signup |
| TUN mode | `--tun=userspace-networking` | Chroot has no `/dev/net/tun`; userspace networking is zero-dependency. Upgrade to kernel TUN later if scp throughput suffers. |
| SSH auth | `tailscale up --ssh` | Identity-based auth from Mac/iPhone. OpenSSH on 2222 stays running for LAN + key-based scripting. |
| Hostname | `moon` | User-chosen nickname, not the Xiaomi device codename. |
| Supervisor | `ksu-moon-ssh/service.sh` launches `tailscaled` after `sshd` | One boot log, sequential start, shares the CE-unlock poll. |

## 1. Install Tailscale in the chroot

Enter the chroot and follow Tailscale's apt install — **but pin the repo to `noble`**, not `resolute`. At time of setup Tailscale had no `resolute` (26.04) pool yet. Safe because Tailscale binaries are statically-linked Go.

Inside `start_ubuntu.sh`:

```
curl -fsSL https://pkgs.tailscale.com/stable/ubuntu/noble.noarmor.gpg | \
    tee /usr/share/keyrings/tailscale-archive-keyring.gpg > /dev/null
curl -fsSL https://pkgs.tailscale.com/stable/ubuntu/noble.tailscale-keyring.list | \
    tee /etc/apt/sources.list.d/tailscale.list
apt-get update
apt-get install -y tailscale
```

Revisit the pin when upgrading to 26.04 LTS on 2026-04-23 — switch to `resolute` if Tailscale has published a pool by then.

## 2. First-run auth

Tailscaled state lives in `/var/lib/tailscale/tailscaled.state` — persistent across reboots. Launch it manually the first time to authorize; subsequent boots just restart the daemon against the same state and need no re-auth.

```
mkdir -p /var/lib/tailscale /var/run/tailscale
nohup /usr/sbin/tailscaled \
    --tun=userspace-networking \
    --state=/var/lib/tailscale/tailscaled.state \
    --socket=/var/run/tailscale/tailscaled.sock \
    > /var/log/tailscaled.log 2>&1 &

tailscale up --ssh --hostname=moon --force-reauth
```

The `tailscale up` command prints a one-time URL. Open it on Mac, approve in the admin console. `tailscale status` should now list `moon <tailnet-ip>`.

## 3. Autostart at boot

`tailscale_setup.sh` is the idempotent restart path — kills any stale `tailscaled`, relaunches with the same flags, then calls `tailscale up --ssh --hostname=moon` to force-reconnect, and logs to `/var/log/tailscaled.log` inside the chroot.

Why the explicit `tailscale up` even though state persists: tailscaled normally auto-reconnects from `tailscaled.state` alone, but a logout-from-admin-console, key expiry, or internal flap leaves the daemon running while the node sits offline on the tailnet. Observed once 2026-05-07. `tailscale up` is a no-op when already connected and recovers the unhealthy case, so it costs nothing on healthy boots.

The flags must match the original interactive `up` — modern Tailscale rejects `up` calls that omit prefs. No `--force-reauth`: the persisted node key is still good, so this is silent unless the key has expired (in which case the boot log gets an auth URL).

It's already pushed to `/data/data/com.termux/files/home/` in phase 3, and `ksu-moon-ssh/service.sh` calls it after `ssh_setup.sh`. No extra install step.

Manual invocation for testing:

```
adb shell su -c 'sh /data/data/com.termux/files/home/tailscale_setup.sh'
```

## 4. Three working entry points

After this phase, there are three ways to reach the chroot:

| Alias | Path | Auth | Reach |
| :--- | :--- | :--- | :--- |
| `ssh moon` | LAN → `MOON_LAN_HOST:2222` | OpenSSH + ed25519 key as `user` | Home Wi-Fi only |
| `ssh moon-ts` | Tailnet → `MOON_TAILNET_HOST:2222` | OpenSSH + ed25519 key as `user` | Anywhere |
| `tailscale ssh root@moon` | Tailnet identity SSH | Tailnet identity (no key file) | Anywhere |

Mac `~/.ssh/config` gets both `moon` and `moon-ts` entries, both with `User user`. Keep them separate rather than routing everything through MagicDNS — the LAN alias stays fast when home.

## 5. Client setup

- **Mac**: `brew install tailscale`, launch, sign into the tailnet account from `config/moon.env`, and record the Mac's tailnet machine name as `MOON_MAC_TAILSCALE_NAME`.
- **iPhone**: App Store → Tailscale, sign in. SSH client: Termius (free) or Blink (paid). Test from cellular.

## Out of scope for v1

- Tailscale Funnel (public HTTPS)
- Subnet router (expose LAN through moon)
- Exit node (route traffic via moon)

All addable later without rework. The chroot is already tailnet-reachable; these are just feature flags on the admin console + `tailscale up` args.

## Gotcha: cold-boot verify needs LAN off

`~/.ssh/config Host moon` resolves to `MOON_LAN_HOST`. When verifying autostart, disable Mac Wi-Fi or force the tailnet path via `ssh moon-ts` — otherwise you can't distinguish "tailscaled up" from "sshd up on LAN".


---

# Phase 5 — AI-agent groundwork (tmux + toolchains)

Install the base toolchains and session-persistence pattern that lets long-running AI agents (OpenClaw, Hermes Agent, anything else) run inside the chroot, survive SSH disconnects, auto-restart on crash, and optionally come up at boot. This phase ships the infrastructure; per-agent install is a separate phase doc.

Prerequisite: phases 2–3 complete — chroot is up, `user` account exists, sshd starts at boot.

## Why tmux, not systemd

The chroot has no PID 1 / systemd by design (see `docs/DESIGN.md`). sshd and tailscaled solve persistence by forking and reparenting to Android's init; that works for daemons that manage their own lifecycle, but AI agents also need:

| Need | sshd-style daemon | AI agent |
| :--- | :--- | :--- |
| Fork to background | ✓ | rarely — most want a controlling terminal |
| Auto-restart on crash | process manager's job | same |
| Interactive attach over SSH | n/a | required (read output, type at prompts) |
| Per-service log | self-managed | expected, not built-in |

A tmux session + a `while true` wrapper covers all four without taking a supervisor dependency. Alternatives considered:

| Option | Verdict |
| :--- | :--- |
| systemd (`--user` or full) | No PID 1 in chroot. Adding one contradicts phase 2's DESIGN.md. |
| `systemd-nspawn` / `proot-distro --boot` | Gives real systemd at the cost of the native-folder architecture. Reject. |
| s6 / runit | Proper supervisor. Overkill for 1–3 agents; right call at 10+. Revisit if service count grows. |
| `nohup` / ad-hoc backgrounding | No crash recovery, no interactive reattach. What we already do for sshd — not enough for agents. |
| tmux + `while true` + tee | **Pick.** Matches existing no-init philosophy, single binary, interactive-friendly. |

## 1. Install the toolchains

One-shot from Android:

```
adb shell su -c 'sh /data/data/com.termux/files/home/agents_setup.sh'
```

`agents_setup.sh` is idempotent. Each run:

1. `apt install tmux curl ca-certificates gpg git` — session manager + the basics any agent's installer will need.
1. Adds the NodeSource `node_24.x` apt repo (signed keyring under `/etc/apt/keyrings/nodesource.gpg`) and installs `nodejs`. Skipped if `node -v` already reports v24+. OpenClaw recommends Node 24; pinning to NodeSource avoids drift when Ubuntu bumps its archive version.
1. Runs Astral's `uv` installer as `user` → `~/.local/bin/uv`. User-scope keeps Python graphs out of `/usr`. Matches the "uv, never pip" rule in `~/.claude/CLAUDE.md`.
1. Installs the `tmux-service` helper at `/usr/local/bin/tmux-service` (source: `scripts/tmux-service.sh`). `/usr/local` is dpkg-untouched, so it survives `apt upgrade`.

Verify from inside the chroot (`ssh moon-user`):

```
tmux -V                # tmux 3.x
node --version         # v24.x
uv --version           # uv 0.x
which tmux-service     # /usr/local/bin/tmux-service
```

## 2. Run a command as a tmux service

`tmux-service` wraps a command in a named, detached tmux session with crash-loop recovery and a log tail. Always run it as the user that should **own** the agent — tmux servers are per-uid, so mixing root and `user` creates two unreachable servers.

```
tmux-service <name> -- <cmd> [args...]
```

Example dry-run (prints dates in a loop, attach, detach, check log):

```
ssh moon-user
tmux-service demo -- sh -c 'echo tick; sleep 5'
tmux attach -t demo               # detach with Ctrl-b d
cat ~/.local/state/moon-agents/demo.log
tmux kill-session -t demo
```

What `tmux-service` does:

- Kills any existing session with the same name (clean redeploy).
- Starts a detached session running `while true; do <cmd>; sleep 2; done 2>&1 | tee -a <log>`.
- Log path: `${XDG_STATE_HOME:-$HOME/.local/state}/moon-agents/<name>.log`.
- `sleep 2` between restarts caps the restart rate at ~0.5 Hz so a tight-crashing agent doesn't burn CPU.

### Common ops

| Task | Command |
| :--- | :--- |
| List running services | `tmux ls` |
| Attach (read + type) | `tmux attach -t <name>` |
| Detach from attached session | `Ctrl-b d` |
| Tail live log | `tail -f ~/.local/state/moon-agents/<name>.log` |
| Stop the service | `tmux kill-session -t <name>` |
| Redeploy with new args | re-run `tmux-service <name> -- <new cmd>` |

## 3. Autostart at boot (opt-in)

Autostart is **off by default**. Boot-time hooks live at `/etc/host-hooks/` *inside the chroot* — Android-side path `/data/data/com.termux/files/home/ubuntu/etc/host-hooks/`. The directory is the general-purpose drop-in point for any host-fired hook (see `ksu-moon-ssh/service.sh`); agents are the first occupant.

The chroot rootfs lives on Android FS at `$UBUNTU=/data/data/com.termux/files/home/ubuntu` (per `start_ubuntu.sh:9`). Pointing `service.sh` (Android context) at a path inside that rootfs lets you manage hooks from inside the chroot with `sudo` — no `adb push`, no chroot-escape, no /sdcard staging. The shebang on `agents_start.sh` stays `/system/bin/sh` because the script itself is still Android-side glue that execs `start_ubuntu.sh`; only its on-disk location moves.

Opt in with a touch-file so you can add/remove without editing scripts:

```
sudo touch /etc/host-hooks/agents.enabled
```

Disable:

```
sudo rm /etc/host-hooks/agents.enabled
```

When the flag is present, `ksu-moon-ssh/service.sh` runs `/etc/host-hooks/agents_start.sh` after sshd and tailscale at `late_start service`. sshd/tailscale exit codes take precedence in the boot log — an agent failing to launch will not mask an ssh regression.

### Configuring which agents start

Edit `scripts/agents_start.sh` in the repo and `sudo cp` it to `/etc/host-hooks/`. One line per agent, run as the owning user. FreelOAder + Hermes are wired up by default (2026-05-07), in that order:

```sh
su -l user -s /bin/sh -c 'tmux-service freeloader -- sh -c "cd /home/user/freeloader && exec .venv/bin/uvicorn freeloader.frontend.app:create_app --factory --host 127.0.0.1 --port 8000"'
su -l user -s /bin/sh -c 'tmux-service hermes -- hermes gateway run --replace'
```

FreelOAder-specific gotchas:

- **Order matters.** `~/.hermes/config.yaml` points `base_url` at `http://127.0.0.1:8000/v1`. Hermes tolerates initial-connect retries, but bringing FreelOAder up first avoids a noisy first turn after boot.
- **`--factory`.** `freeloader.frontend.app:create_app` is a factory function (it constructs a `Router` from `load_router_config()`), not a module-level `app`. Without `--factory`, uvicorn tries to import an attribute that doesn't exist.
- **`cd /home/user/freeloader` is load-bearing.** `.venv/bin/uvicorn` is relative, and `freeloader.toml` (when present) is resolved from cwd before falling back to `~/.local/share/freeloader/freeloader.toml`.
- **Editable install survives reboot, build cache does not.** `.venv/lib/.../site-packages/_editable_impl_freeloader.pth` points at `src/`, so no rebuild is needed at boot. If you ever re-run `uv sync`, see freeloader's `README.md` § "Run the server" for the f2fs/SELinux build-cache trap.
- **Port / factory-path changes touch four spots.** `127.0.0.1:8000` and the `--factory` target are encoded in (a) the live `tmux-service` invocation, (b) `scripts/agents_start.sh` here, (c) the deployed copy at `/etc/host-hooks/agents_start.sh`, AND (d) `~/.hermes/config.yaml`'s `base_url`. Change any without the others and Hermes either can't connect or hits a stale gateway.

Hermes-specific gotcha: `hermes gateway install` writes a systemd-user unit at `~/.config/systemd/user/hermes-gateway.service` and `hermes gateway start` invokes that unit. Both are dead in this chroot — no PID 1 / no systemd-user. Use `hermes gateway run` (Hermes flags as "recommended for WSL, Docker, Termux") and let `tmux-service` supply the supervisor layer. `--replace` clears any lingering hermes process from a prior boot before binding the gateway socket. If you ran `hermes gateway install` before this migration, `rm ~/.config/systemd/user/hermes-gateway.service` to clean up — `hermes gateway uninstall` itself trips on `systemctl --user daemon-reload`, so the rm is the working uninstall path here.

OpenClaw remains optional — pattern is the same:

```sh
su -l user -s /bin/sh -c 'tmux-service openclaw -- openclaw gateway --port 18789'
```

Deploy from inside the chroot:

```
sudo install -d /etc/host-hooks
sudo cp scripts/agents_start.sh /etc/host-hooks/agents_start.sh
sudo sh /etc/host-hooks/agents_start.sh    # optional dry-run
```

Re-pushing after edits is just the second `cp`. The hook file's on-disk path is fixed; iterate on the source in the repo and copy over. The deployed copy is root-owned but world-readable (`chmod go+r`), so a non-root checkout can verify-without-sudo:

```
cmp /etc/host-hooks/agents_start.sh scripts/agents_start.sh   # deployed matches repo
ls /etc/host-hooks/agents.enabled                              # autostart on
sudo grep agents_start /var/log/moon-ssh-boot.log              # boot-time trace (Android-side log, sudo only)
```

Re-running `/etc/host-hooks/agents_start.sh` by hand kill+restarts every wired-up service — `tmux-service` does a clean redeploy on each invocation (see § 2). Don't trigger it just to test syntax; `sh -n /etc/host-hooks/agents_start.sh` parse-checks without side effects.

Then reboot (or power-cycle) and confirm:

```
ssh moon grep agents_start /var/log/moon-ssh-boot.log
ssh moon-user -t tmux ls
```

## 4. Attach from a Mac shortcut

Add to Mac `~/.ssh/config` alongside the existing `moon-user` entry — nothing new to configure, but a one-liner to jump straight into an agent session is convenient:

```
alias agent-openclaw='ssh moon-user -t tmux attach -t openclaw'
alias agent-hermes='ssh moon-user -t tmux attach -t hermes'
```

`-t` forces a pty so tmux can drive it. Detach with `Ctrl-b d` — the service keeps running on the phone.

## 5. Next: install an agent

With the groundwork in place, adding an agent is:

1. Install the agent (inside the chroot as `user`) — e.g. `npm i -g openclaw` or `uv tool install hermes` / upstream installer.
1. First-run configuration (API keys, pairing, whatever the agent's onboarding requires).
1. Add a `tmux-service <name> -- <start-cmd>` line to `scripts/agents_start.sh` and `sudo cp` it to `/etc/host-hooks/`.
1. `sudo touch /etc/host-hooks/agents.enabled` if not already done.

Per-agent playbooks (OpenClaw, Hermes) live in their own phase docs — this one stops at groundwork.

## Gotchas

- **Log growth is unbounded.** `tee -a` keeps appending. Rotate manually (`truncate -s 0 ~/.local/state/moon-agents/<name>.log`) or drop a `logrotate` snippet in `/etc/logrotate.d/moon-agents` if an agent turns chatty.
- **Crash-loop storms aren't surfaced.** If an agent crashes every 2 s, only the log shows it. Future: add a simple rate-check in `tmux-service` that bails after N crashes in M seconds. Defer until it bites.
- **tmux server dies on reboot.** Expected — sessions are in-memory. Boot-time launch recreates them. If you reboot without `agents.enabled` set, no services come back.
- **Node 24 from NodeSource pins major.** When Node 26+ comes out and an agent needs it, bump the repo line in `agents_setup.sh` (`node_24.x` → `node_26.x`) and re-run.
- **`uv` installer fetches the latest release.** Pinned by the Astral install script, not by us. Re-running `agents_setup.sh` will upgrade `uv` in place; revert by `uv self update <old>` if an upgrade breaks a pinned tool.


---
