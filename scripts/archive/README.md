# scripts/archive/

Quarantined scripts kept for historical reference. **Do not run against a live deployment** — the conditions they were designed for no longer exist, and in some cases running them now would regress mitigated footguns.

## `cleanup_mounts.sh`

Lazy-unmounts every mount under the three mirrored Ubuntu paths (`/data/data/.../ubuntu`, `/data_mirror/data_ce/null/0/.../ubuntu`, `/data/user/0/.../ubuntu`). Written pre-2026-04-20 when `start_ubuntu.sh` still `--rbind`'d `/dev` and a failed chroot entry would leave propagated mounts unreachable from root.

**Why archived:** `start_ubuntu.sh` switched to a narrow tmpfs-backed `/dev` (2026-04-20), which eliminated the rbind-footgun class entirely. The script has no use case on the current stack. Running it against a live chroot risks vaporizing the host's binderfs mount via mount propagation — see `docs/HISTORY.md` §2 "Binderfs-wipes-all-apps pitfall".

If you hit a stuck-mount situation on a future rework, read the script for reference rather than invoking it blind.
