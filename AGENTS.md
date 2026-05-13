# Poco F5 (marble) Ubuntu Migration: Agent Context

This directory manages the high-performance deployment of a bare-metal Ubuntu 26.04 chroot environment on the Poco F5 (marble).

## Project Overview
The objective is to transform a Poco F5 (Snapdragon 7+ Gen 2) into a high-efficiency ARM64 server by deploying Ubuntu directly into a native filesystem folder within Android's `/data` partition, eliminating I/O overhead from loopback images.

### Key Technologies
| Component | Specification |
| :--- | :--- |
| **Device** | Poco F5 5G (`marble`, model `23049PCD8G`, TW Global SKU) |
| **SoC** | Snapdragon 7+ Gen 2 (4nm) |
| **CPU** | 1x 2.91GHz X2, 3x 2.49GHz A710, 4x 1.8GHz A510 |
| **GPU** | Adreno 725 |
| **Storage** | UFS 3.1 |
| **NFC** | Present (Global SKU has NFC hardware; India SKU 23049PCD8I is the hardware-omitted variant) |
| **Biometrics** | Side-mounted fingerprint sensor in power button (all variants) |
| **Host OS** | LineageOS 23.2 (`20260414-nightly-marble-signed`, Android 16 / AOSP) — booted 2026-04-19 after EvoX 15/16 pivot |
| **Guest OS** | Ubuntu 26.04 LTS (Resolute Raccoon) ARM64 — upgraded from beta to final via apt on 2026-04-21 |
| **Environment** | Termux + Chroot (KernelSU-Next root, **not** Magisk) |
| **Networking** | Headless CLI via non-root OpenSSH (`user`) plus Tailscale SSH |

## Directory Overview
- `README.md`: Human-facing entry point — end state, read order, repo layout.
- `docs/DESIGN.md`: The foundational philosophy of the project, detailing the shift from loopback images to native folder storage and performance tuning strategies.
- `docs/INSTALLATION.md`: The consolidated installation playbook covering LineageOS flashing, Ubuntu chroot, remote access, and agent setup.
- `docs/MAINTENANCE.md`: Operate/update/troubleshoot/recover a running server. Re-KSU after Lineage OTA, Ubuntu `apt upgrade`, log locations, bootloop escape hatches, backups.
- `docs/LESSONS.md`: Consolidated architectural findings, decisions, and historical gotchas. Read before changing the stack.
- `config/`: Public `moon.env.example` plus gitignored `moon.env` for live LAN/tailnet/ADB/SSH values.
- `scripts/`: Shell scripts that run on the device. Source-of-truth copy; on-device copies live at `/data/data/com.termux/files/home/` (for phase 2/3 scripts) and `/data/adb/modules/moon-ssh/` (for the KSU module).
- `roms/`: ROM binaries, firmware images, rootfs tarball. **Gitignored** (17 GB).
- `AGENTS.md`: (This file) Instructional context and project mandates for any AI assistant.

## Key Files & Assets (External to CWD)
- Active ROM: `roms/lineage23/lineage-23.2-20260414-nightly-marble-signed.zip` (1.8 GB signed OTA, installed 2026-04-19)
- Lineage core images: `roms/lineage23/` (`boot.img`, `dtbo.img`, `vendor_boot.img`, `recovery.img`, `vbmeta.img`, `super_empty.img`)
- Fallback firmware (for radio repair if Lineage modem breaks): `roms/hyperos-tw/marble_tw_global-ota_full-OS2.0.211.0.VMRTWXM-user-15.0-d0006b2702.zip` (5.4 GB HyperOS A15, payload.bin-based)
- Stranded EvoX assets (do NOT flash on Lineage): `roms/15/`, `roms/KSU/`, `roms/0416/`, `roms/0417/`
- Tools: `adb`, `fastboot`, `payload-dumper-go`.

## Operational Mandates
1. **State-First Documentation:** Whenever a state change occurs (e.g., firmware uploaded, issue encountered, task completion), update project files (specifically `docs/LESSONS.md` or `docs/MAINTENANCE.md` depending on relevance) **BEFORE** proceeding with the next action.
1. **Agent-Agnostic State:** All project facts, decisions, observations, and plans live in project files (`docs/LESSONS.md`, `docs/DESIGN.md`, phase docs under `docs/`, scripts, this file). Do NOT store project context in agent-private systems (Claude auto-memory, Cursor rules, IDE-specific config, custom context caches). If another agent or a human reader cannot find it by reading this directory, it is effectively lost. Agent-side memory is reserved for agent-specific collaboration preferences, never for project state.
1. **AI-Driven Execution:** All technical commands (`fastboot`, `adb`, etc.) must be issued by the AI to ensure consistency and logging.
1. **Dedicated ROM Workspace:** Use the `roms/` directory within the workspace for all ROM zips, recovery images, and extracted core files.
1. **Prioritize Native I/O:** Always favor direct directory manipulation over `.img` based solutions.
1. **Performance First:** Prefer the measured Lineage defaults (`walt` CPU governor, `bfq` I/O scheduler) unless troubleshooting proves a bottleneck. Use `performance` governors only as a targeted screen-off/throttling diagnostic or temporary mitigation.
1. **Headless Workflow:** Focus on SSH/CLI management. Avoid sensory-heavy GUI wrappers or VNC-based solutions unless explicitly requested.
1. **A/B partition awareness:** `marble` is A/B with a dedicated slotted `recovery_a/b` partition (100 MiB each). Lineage variant1 guide uses unslotted names (`fastboot flash boot`) which hit the active slot only — OTA populates the other slot on install. For explicit dual-slot coverage use `_a`/`_b` suffixes (no `--slot=all` support in current fastboot).

## Usage
Start with `README.md`, then use `docs/MAINTENANCE.md` for current operations, `docs/INSTALLATION.md` for rebuild/install procedures, and `docs/LESSONS.md` for decisions and gotchas. Source `config/moon.env` in private checkouts for live values; all technical commands (`fastboot`/`adb`) should target `$MOON_ADB_SERIAL` when multiple devices are present.
