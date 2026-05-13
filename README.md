# marble-server

> **⚠️ Disclaimer:** This project involves unlocking the bootloader, flashing custom ROMs, gaining root access, and directly modifying the `/data` partition. These operations carry a significant risk of permanently bricking your device or causing data loss. **Use at your own risk.** The authors are not responsible for any hardware damage or data loss.

Turning a Xiaomi Poco F5 5G (`marble`, Snapdragon 7+ Gen 2) into a headless ARM64 mini-server — LineageOS 23.2 underneath, Ubuntu 26.04 in a native-filesystem chroot, reachable over LAN and Tailscale.

**End state:** `ssh moon` on LAN, or `ssh moon-ts` over Tailscale, lands as the non-root `user` in an Ubuntu shell running on the phone. No GUI, no desktop environment, no cellular. Ubuntu's rootfs lives directly on `/data` (no loopback image) for maximum I/O throughput.

## Hardware & ROM

| Component | Pick |
| :--- | :--- |
| Device | Poco F5 5G Global (`marble`, model `23049PCD8G`) |
| Host OS | LineageOS 23.2 (Android 16 / AOSP) |
| Root | KernelSU-Next v3.2.0 (LKM, `android12-5.10` KMI) |
| Guest OS | Ubuntu 26.04 ARM64 in chroot |
| Remote access | OpenSSH on LAN + Tailscale SSH on WAN |

## Read order

| Doc | Purpose |
| :--- | :--- |
| [`docs/DESIGN.md`](docs/DESIGN.md) | Architecture rationale — why native chroot, why LineageOS, why KSU-Next |
| [`docs/INSTALLATION.md`](docs/INSTALLATION.md) | Full installation playbook (Phases 1-5): LineageOS, Ubuntu chroot, OpenSSH, Tailscale, and AI agents |
| [`docs/MAINTENANCE.md`](docs/MAINTENANCE.md) | Day-to-day ops, updates (incl. re-KSU after Lineage OTA), troubleshooting, recovery, backups |
| [`docs/LESSONS.md`](docs/LESSONS.md) | Architectural findings, lessons learned, and historical gotchas. Read before changing the stack. |

## What's in this repo

- `docs/` — design, install playbooks, lessons learned (`LESSONS.md`)
- `config/` — tracked local-config template plus gitignored `moon.env` for live deployment values
- `scripts/` — shell scripts that run on the device
  - `start_ubuntu.sh` — chroot entry (narrow `/dev` binds, DNS, hostname)
  - `extract.sh` — unpack the Ubuntu rootfs tarball into `/data/data/com.termux/files/home/ubuntu`
  - `apt_bootstrap.sh` — first-run `apt update` + base package install
  - `ssh_setup.sh` — configure OpenSSH on port 2222, idempotently provision the non-root `user` account
  - `authorized_keys.example` — template for the gitignored live `scripts/authorized_keys` allowlist installed for the OpenSSH `user` account
  - `tailscale_setup.sh` — start `tailscaled` in userspace-networking mode
  - `agents_setup.sh` — install AI-agent toolchains (tmux, Node 24, uv) + the `tmux-service` helper
  - `agents_start.sh` — boot-time launcher for AI agents (opt-in via `agents.enabled` flag file)
  - `tmux-service.sh` — source-of-truth for `/usr/local/bin/tmux-service`: run a command in a detached tmux session with crash-loop recovery and log tee
  - `android-lock.sh`, `android-unlock.sh` — manual screen-off / wake over the chroot-escape path (counter to screen-off CPU throttling; see `docs/MAINTENANCE.md` §1)
  - `reboot.sh` — root helper deployed at `/usr/local/sbin/reboot`; schedules detached reboot then SIGHUPs the per-session sshd for a clean disconnect (called by `user` through the `/usr/local/bin/reboot` sudo wrapper)
  - `ksu-moon-ssh/` — KSU-Next module that autostarts sshd + tailscaled (+ agents, if enabled) at `late_start service`
  - `archive/` — quarantined scripts (see `archive/README.md`)
  - `SHA256SUMS`, `SHA256SUMS.gpg` — Ubuntu CD Image signed integrity files for the rootfs tarball
- `roms/` — ROM binaries, firmware images, rootfs tarball. **Gitignored** (17 GB).
- `AGENTS.md` — operational mandates for AI assistants working in this repo

## Device nickname

Throughout the docs the device is called **moon** — the hostname in the chroot, the alias in `~/.ssh/config`, the Tailscale machine name. "Marble" still refers to Xiaomi's hardware codename.

Live deployment values for this checkout belong in the gitignored `config/moon.env`; public docs use the variable names from `config/moon.env.example`.
