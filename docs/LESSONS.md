# Lessons Learned & Gotchas

Consolidated architectural findings and historical gotchas from the marble-server migration process.

## 1. ROM, Kernel & Root

- **ROM Choice:** LineageOS 23.2 (A16) is the stable foundation. EvolutionX 16 bootlooped repeatedly after Format Data, and EvoX 15 had sideload issues. LineageOS provides a cleaner, more predictable environment. HyperOS remains only as a cold-storage recovery fallback (cellular permanently unused).
- **vbmeta Flashing:** Flashing `vbmeta` with `--disable-verity` fails on modern fastboot. Simply flash `vbmeta_a`/`vbmeta_b` plain (no flags). The bootloader unlock will show ORANGE state (warning), but the KSU-patched boot still loads fine.
- **KMI Version:** Even though LineageOS 23.2 is Android 16, the Poco F5 (`marble`) uses an older Google Generic Kernel Image (GKI) base. The correct KMI for KernelSU-Next patching is **`android12-5.10`**. Patching with A13 fails silently.
- **Root access verification:** `/sys/module/kernelsu/version` and similar paths return `ENOENT` with KSU-Next v3.2.0 LKM mode. Verify root via the Manager app or Termux. Also, `adb shell su` will say `not found` because root is granted per-app; use `adb shell su -c '<cmd>'` through the shell profile instead.
- **Recovery Sideloading:** Lineage recovery enforces signed sideloading. Unsigned AnyKernel3 zips will fail. Always use in-Android boot.img patching (KernelSU Manager) instead of sideloading kernel zips.

## 2. Ubuntu Chroot Deployment

- **Native Folder over Loopback:** Deploying Ubuntu directly into `/data/data/com.termux/files/home/ubuntu` avoids loopback I/O overhead on UFS 3.1. This is the core architectural premise of the project.
- **KSU Profile for Termux:** The KSU profile for Termux **must** grant ALL capabilities and use the **Global mount namespace**. Otherwise, `chroot()` fails silently with "Permission denied", and Termux's `/data` files stay hidden from root.
- **The Binderfs Pitfall:** **Never use `--rbind /dev` into the chroot.** This replicates Android's `binderfs`. A lazy unmount against the chroot's tree propagates up and destroys the host's binderfs, crashing every Android app. `start_ubuntu.sh` is strictly designed to mount only narrow leaf nodes (tmpfs `/dev`, `devpts`, `shm`, and `mknod` char devices).
- **`/data` `nosuid` Quirks:** Android's `/data` partition is mounted `nosuid`. Binaries like `sudo` won't work natively. `start_ubuntu.sh` fixes this by bind-mounting the chroot root onto itself and remounting with `suid,exec,dev`.
- **sudo-rs:** Ubuntu 26.04 uses `sudo-rs` by default instead of classic sudo.
- **DNS Resolution:** `/etc/resolv.conf` is forcefully rewritten to public DNS (1.1.1.1, 8.8.8.8) on every chroot entry because Ubuntu's `systemd-resolved` leaves a dangling symlink (since we don't run systemd).
- **SSH Ghost Processes:** Ungraceful disconnects can leave `sshd` sessions in a hung state where they appear in the process list but the listener socket is gone. **Layer A Hardening** (`ClientAliveInterval 30`, `ClientAliveCountMax 4`) forces the server to reap these dead sessions after 2 minutes.

## 3. Remote Access & Boot Process

- **SSH safe reboot:** Running a standard `sudo reboot` inside the chroot hangs the SSH socket because the kernel panics before flushing the TCP connection. Use the provided `/usr/local/sbin/reboot` wrapper, which detaches file descriptors and returns instantly.
- **OpenSSH is non-root:** `ssh_setup.sh` sets `PermitRootLogin no` and installs the gitignored live `config/authorized_keys` only for the non-root `user` account. Routine admin goes through `sudo`; first-time password setup or root recovery uses `adb shell su` or Tailscale identity SSH where ACLs allow it.
- **Tailscale over alternatives:** Tailscale SSH combined with userspace networking (`tailscaled --tun=userspace-networking`) is the optimal remote access path for this chroot, avoiding kernel module tuning while easily piercing CGNAT.
- **Boot script constraints:** The boot process happens in two stages because `/data/data/com.termux/files/home/` (CE storage) takes a few seconds to unlock and populate during KSU's `late_start`. Logging during this phase relies on a temporary location (`/data/local/tmp/moon-ssh-boot.log`) before moving into the chroot log path. 
- **ADB Push Permission Hurdles:** Direct `adb push` to `/data/data/com.termux/files/home/` often fails even as root because of how Android handles app-data permissions and SELinux. Reliable deployment method: `adb shell su -c 'cat > /path/to/target' < local_file` to bypass the `push` UID mismatch.
- **tmux Auto-Start for SSH:** To prevent dropped connections, interactive SSH logins are automatically routed into an independent, named tmux session (`ssh_$$`) via a profile script. This avoids hijacking background AI agents (which do not use the `ssh_` prefix) while ensuring multiple concurrent SSH clients don't suffer from forced pane resizing.

## 4. Performance & Android Nuances

- **Lineage Defaults are Optimal:** Extensive load testing showed that LineageOS's default CPU governor (`walt`) and I/O scheduler (`bfq`) scale perfectly under load. The X2 prime core easily hits 2.91 GHz when needed. No manual tweaking of cpufreq or cpusets is necessary.
- **Screen-Off Throttling Mitigation:** Keeping the device plugged in with Developer Options **Stay awake while charging** enabled is the definitive fix for CPU throttling.
- **Manual Lock/Unlock Escapes:** The `android-lock.sh` and `android-unlock.sh` scripts handle ad-hoc screen management. They use absolute paths dynamically linked to `/system/bin/linker64` and must run outside the chroot (escaped via `chroot /proc/1/root`).

## 5. AI Agents

- **Daemon Management:** Without `systemd` in the chroot, long-running agent processes (like Hermes or Freeloader) are managed via `tmux-service.sh`, which background-forks robust named tmux sessions.
- **Hermes Gateway:** Run Hermes via `gateway run` rather than `gateway install`, as the latter relies on systemd-user units which are dead in this environment.
