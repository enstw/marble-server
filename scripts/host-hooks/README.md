# Boot hooks (`scripts/host-hooks/`)

Source of truth for the chroot's boot hooks. These files are deployed to
`/etc/host-hooks/*.hook` **inside the Ubuntu chroot** (Android-side path
`$UBUNTU/etc/host-hooks/`, `$UBUNTU=/data/data/com.termux/files/home/ubuntu`).

At boot, the KSU module `ksu-moon-ssh/service.sh` enters the chroot **once** at
`late_start service` and runs every `*.hook` here, in lexical order, **as root
inside the chroot**. One file = one hook.

Full playbook — deploying, configuring agents, troubleshooting the boot log —
lives in [`docs/INSTALLATION.md` § "Boot hooks"](../../docs/INSTALLATION.md).
This README is just the contract for writing/editing a hook.

## The hooks

| File | Runs | Default |
| :--- | :--- | :--- |
| `10-sshd.hook` | start OpenSSH (port 2222) | enabled |
| `20-tailscale.hook` | start tailscaled (userspace networking) + `tailscale up` | enabled |
| `50-agents.hook` | **template** — launches the AI agents you uncomment/add (freeloader, hermes, openclaw examples included) | **disabled** (deployed as `.disabled`) |

Numeric prefix = run order. Keep gaps (10/20/50) so new hooks can slot between.

## The contract

- **Runs as root, inside the chroot.** The chroot mounts/binds are already set
  up by `start_ubuntu.sh`; a hook is a plain in-chroot script. Use `#!/bin/sh`
  unless you need bash.
- **Drop privileges with `run-as`.** To run something as the non-root `user`:
  `run-as user -- <cmd>` (= `su -l user -s /bin/sh -c …`; see `../run-as.sh`).
  Don't hand-roll `su` — `run-as` gets the login env, shell, and quoting right.
- **Start-only.** Hooks launch *already-provisioned* services; boot does **not**
  re-provision. Provisioning (users, configs, keys, package installs) belongs in
  the `*_setup.sh` scripts. If a hook needs something that may be missing, fail
  loudly (see `10-sshd.hook`'s guard on `sshd_config.d/10-moon.conf`) rather than
  coming up half-configured.
- **Be idempotent + self-contained.** A hook may run on any boot with no prior
  state beyond what provisioning left. `pkill` stale instances before starting.
- **Daemons must detach.** The chroot session ends when the hook loop finishes,
  so background long-lived processes (`nohup … &`, `sshd` self-daemonizes,
  `tmux-service` spawns a detached server) — anything still attached dies.
- **Exit codes matter.** Each hook runs in its own subshell, so one failing
  hook can't abort the others. The runner reports the **first** non-zero rc, and
  hooks run in order, so a low-numbered failure (10-sshd) is never masked by a
  later one. Return non-zero only for a real failure.

## Enable / disable

Rename — the runner globs `*.hook`, so a `.disabled` suffix takes a hook out of
the boot set without deleting it:

```sh
sudo mv /etc/host-hooks/50-agents.hook.disabled /etc/host-hooks/50-agents.hook   # enable
sudo mv /etc/host-hooks/50-agents.hook /etc/host-hooks/50-agents.hook.disabled   # disable
```

## Deploying

Normally automatic: each `*_setup.sh` deploys its own hook during provisioning
(`ssh_setup.sh` → `10-sshd`, `tailscale_setup.sh` → `20-tailscale`,
`agents_setup.sh` → `50-agents.hook.disabled`), reading it from Termux home — so
push `*.hook` there alongside the setup scripts, and a chroot rebuild redeposits
them. To iterate on one hook without full provisioning:

```sh
sudo install -m 0755 scripts/host-hooks/10-sshd.hook /etc/host-hooks/10-sshd.hook
```

`sh -n <hook>` parse-checks without side effects. Running a hook by hand
re-applies it for real (kills + restarts the service) — don't do it just to test
syntax.

## Adding a new hook

1. Write `scripts/host-hooks/NN-<name>.hook` to the contract above. Pick `NN` to
   place it in run order (after sshd/tailscale unless it must precede them).
2. Deploy it (auto via a `*_setup.sh`, or `sudo install` for a one-off). Ship it
   `.disabled` if it should be opt-in.
3. `sh -n` it, reboot, and check `/var/log/moon-ssh-boot.log` for its
   `=== hook NN-<name> ... ===` markers.
