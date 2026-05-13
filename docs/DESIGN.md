To extract bare-metal maximum performance for Ubuntu on an Android SoC, the goal is to eliminate all abstraction layers, emulation, and I/O bottlenecks. 

### The Most Significant Difference: Native Directory vs. Loopback Image
The absolute biggest performance killer in mobile Linux deployments is the storage format. Traditional tools (like Linux Deploy) construct a loop-mounted `.img` file. This forces the system to translate file operations through a virtual disk image, introducing significant I/O latency. 

For maximum read/write speeds, the Ubuntu filesystem must be deployed directly into a native folder on your phone's internal `/data` partition (which utilizes highly optimized `f2fs` or `ext4` filesystems). 

Here is the ultimate stack for pure performance, stability, and architectural control.

### 1. The Foundation: LineageOS 23.2 + KSU-Next (boot.img patch)
* **Target Device:** **Poco F5 5G Global (marble, model `23049PCD8G`)** — variant1 in the Lineage wiki.
* **Chipset:** **Snapdragon 7+ Gen 2** (Adreno 725 GPU).
* **ROM:** **LineageOS 23.2** (build `20260414-nightly-marble-signed`, 1.8 GB, Android 16 / AOSP-based, official marble nightly). Pivoted from EvolutionX on 2026-04-19 after EvoX 16 dailies (20260416 + 20260417) bootlooped post-Format-Data and EvoX 15 was subsequently abandoned — see [`HISTORY-archive.md`](HISTORY-archive.md) "EvoX → Lineage pivot" section.
* **Install path (per Lineage wiki variant1, with root-friendly additions):** fastboot-flash `boot.img`, `dtbo.img`, `vendor_boot.img`, plus `vbmeta.img` with `--disable-verity --disable-verification` (additive to the wiki — relaxes AVB/dm-verity so the KSU-patched boot.img later doesn't fail verification), then reboot-bootloader, flash `recovery.img`, reboot-recovery, format-data, sideload the signed OTA. The wiki uses **unslotted** partition names — `fastboot flash boot` targets the currently-active slot only; the OTA installer populates the opposite slot on first install. `super_empty.img` is staged in `/roms/lineage23/` but unused — hold in reserve for dynamic-partition corruption.
* **Firmware / cellular: N/A.** Device runs **airplane mode + wifi always** (user decision 2026-04-19) — no SIM, no cellular, no modem traffic. Lineage 23.2's nominal Android-15-stock-firmware prerequisite (modem/tz/xbl/abl) therefore doesn't matter: radio state is irrelevant when the radio is off forever. The HyperOS A15 fallback (`roms/hyperos-tw/marble_tw_global-ota_full-OS2.0.211.0.VMRTWXM-user-15.0-d0006b2702.zip`) stays staged only as a last-resort recovery ROM if Lineage itself ever breaks catastrophically — not as a "fix broken cellular" path.
* **Kernel + Root — Path A (default):** Install **KernelSU-Next Manager** APK on running Lineage 23 → patch the stock Lineage `boot.img` in-app → `adb pull` patched image → `fastboot flash boot patched_boot.img` (active slot; OTA will sync the other slot on next update). Gives kernel-space root on the stock Lineage kernel. Sufficient for the chroot use case; susfs (root hiding) is unnecessary because no banking apps run here. The previous `Evo-*-KSU-Next-susfs.zip` AnyKernel3 zips in `/roms/15/` and `/roms/KSU/` are **EvoX-specific** (different ROM, different Android version, incompatible vendor_boot pairing) — quarantined, do not flash on Lineage.
* **Path B (fallback):** If step 4 tunables demand a custom kernel, temp-boot TWRP/OrangeFox via fastboot and sideload a Lineage-flavored AnyKernel3 zip with KSU-Next + susfs. Not needed for the chroot baseline.

### 2. The Deployment: Termux Root Chroot
* **Engine:** Termux (from F-Droid), granted Superuser via **KSU-Next Manager** — not Magisk. **Why F-Droid client instead of `adb install`-ing the Termux APK directly:** (1) source-of-trust — F-Droid builds Termux from source and signs with its own key, giving a verifiable supply chain distinct from upstream GitHub; (2) auto-updates for Termux and any future FOSS apps (termux-api, etc.) without manual APK wrangling. Cost is one extra app on device; acceptable.
* **Guest OS:** **Ubuntu 26.04 (Resolute Raccoon) ARM64** — currently beta (`ubuntu-base-26.04-beta-base-arm64.tar.gz`, 34 MiB, built 2026-03-25). Extracted to **`/data/data/com.termux/files/home/ubuntu`** as a native `f2fs`/`ext4` directory — no loopback `.img`. Roll forward to final LTS via `apt update && apt full-upgrade` after release on 2026-04-23.
* **Method:** `start_ubuntu.sh` bind-mounts `/dev`, `/proc`, `/sys`, `/tmp`, `/sdcard` into the rootfs and `chroot`s in.
* **Advantage:** Complete architectural transparency. Hand-scripted rather than using an opaque GUI app, with zero CPU emulation overhead and explicit control over which Android interfaces the chroot can see.

### 3. The Access Layer: Headless Operation
* **CLI over GUI:** Running a graphical desktop environment (even a lightweight one like XFCE) inherently consumes RAM and CPU cycles for visual rendering.
* **The Protocol:** For absolute maximum efficiency, run the Ubuntu environment entirely headless. Install `openssh-server` within the chroot and interface with it via an SSH client. This allows you to manage the device exactly like a high-performance, self-hosted ARM micro-server.
