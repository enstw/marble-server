# Local Config

`moon.env` is the private, live config for operating a specific device. It is gitignored so the public repo can stay generic while this checkout still knows how to reach `moon`.

Create it from the example:

```sh
cp config/moon.env.example config/moon.env
```

Then edit `config/moon.env` with the LAN IP, tailnet hostname/domain, SSH identity path, and ADB serial for the local deployment.

To use the values in a shell:

```sh
set -a
. config/moon.env
set +a
```

`scripts/authorized_keys` is also gitignored. Keep the live allowlist there on deployed/private checkouts; public clones should start from `scripts/authorized_keys.example`.

## Private Config Repo

A private GitHub companion repo works well for non-secret live config:

```text
marble-server/                 # public repo
  config/moon.env.example
  scripts/authorized_keys.example
  config/moon.env              # ignored local file or symlink
  scripts/authorized_keys      # ignored local file or symlink

marble-server-config/          # private repo
  moon.env
  authorized_keys
  README.md
```

Link the private files into a working public checkout:

```sh
ln -s ../marble-server-config/moon.env config/moon.env
ln -s ../marble-server-config/authorized_keys scripts/authorized_keys
```

Keep true credentials out of GitHub unless encrypted: SSH private keys, Tailscale state, passwords, recovery codes, and API tokens belong in a password manager or an encrypted `sops`/`age` file.
