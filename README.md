# ventoy-stick

A profile-based Ventoy provisioning stick that stands up an Ubuntu Server
machine end to end without touching a keyboard on the target: pick the stick
in the boot menu, walk away, come back to a machine with SSH keys installed,
agent tooling running, and every stand-up step (sudo, GPU driver, build
caches, VPN, policy files) already applied and smoke-tested.

Built for a two-machine workflow: one control machine that owns Git,
credentials, and planning; one or more compute boxes provisioned from this
stick that exist only to execute work over bounded SSH.

## How it works

Three phases, none of which require interactive input on the target:

1. **Installer (subiquity autoinstall).** Ventoy's `auto_install` injects the
   per-profile cloud-init seed (CIDATA). The seed wipes the largest disk,
   installs Ubuntu Server, installs the profile's SSH keys, writes the
   passwordless-sudo fragment and the first-boot completion unit directly
   into the fresh system, and powers off. On a Ventoy boot the whole stick
   reads as read-only (the ISO device-mapper holds the disk), so the install
   can never write back to the stick: that constraint is why everything the
   installer needs travels inside the seed.
2. **First boot (provision-retry.service).** With the stick still inserted it
   mounts as a normal writable disk, and a conditional systemd unit runs the
   provisioner until every step passes: agent binaries and credentials, the
   baseline tool set, the stand-up layer, the router listeners, and two real
   model-call smokes checked against exact markers. Failures withhold the
   completion marker and retry on the next boot.
3. **Manual remainder.** Only three things stay manual by design: authorizing
   the new ZeroTier node in ZeroTier Central, re-establishing trust on the
   control machine (host keys changed), and whatever optional extras a box
   needs. See [BRINGUP.md](BRINGUP.md).

## Repository layout

| Path | What |
| --- | --- |
| `stick/README.md` | The stick's own documentation: flows, profiles, secrets, caveats |
| `stick/provision/bootstrap.sh` | The provisioner (first boot / desktop flow) |
| `stick/provision/files/` | Baseline installer, router config examples, model catalog, policy file slot |
| `stick/provision/profiles/example/` | Documented example profile (real profiles are gitignored) |
| `stick/ventoy/` | Generated per-profile autoinstall seeds + boot menu (gitignored) |
| `tools/make-profile.sh` | Creates a profile: identity, keys, secrets bundle, seed, boot menu |
| `tools/sync-stick.sh` | Stages the tree onto the physical stick (exFAT-safe, manifest hash) |
| `tools/assemble-stick.sh` | One-shot stick assembly from scratch (destroys the data partition) |
| `tools/build-ccr-linux.sh` | Cross-builds the router binary (musl static) |
| `tools/tests/` | Docker-based test suite for the provisioner and installer hook |
| `BRINGUP.md` | Post-install runbook: what's automated, what's manual, verified gotchas |

## What lands on a fresh machine

- Ubuntu Server 26.04 (autoinstall) with the profile's SSH keys
- Codex CLI + a local CCR router (user systemd services: main listener on
  3456, GLM worker listener on 3457) with real credentials from the
  profile's secrets bundle
- Claude Code + a `claude-ccr` launcher + client routing settings
- Baseline operator tooling (`uv`, `ruff`, `ty`, `hf`, `ccache`, `sccache`,
  `rg`/`fd`/`bat`/`delta`, `gh`, `rclone`, and the rest of the list in
  `files/install-baseline-tools.sh`)
- Passwordless sudo for the profile user
- Build-cache wiring (absolute-path sccache wrapper, profile.d exports,
  ccache 50G + inode_cache)
- Policy files (`AGENTS.md` core + the import stub other CLIs read)
- Optional per profile: NVIDIA driver + persistence daemon (+ nvtop, + CUDA
  toolkit), ZeroTier join
- Acceptance: a real Codex turn and a real Claude turn through the local
  router, each verified by an exact response marker; verdict line is
  machine-parseable in `/var/log/ventoy-bootstrap.log`

## Build a stick from scratch

Requirements: a USB drive, [Ventoy](https://www.ventoy.net) >= 1.1.12
installed on it, and a data partition formatted exFAT with the volume label
exactly `Ventoy`.

```sh
# 1. ISOs into isos/ (checksums verified against releases.ubuntu.com)
# 2. Router binary (or drop in your own): tools/build-ccr-linux.sh
# 3. Codex binaries: download the musl release artifacts of
#    openai/codex into stick/provision/bin/
# 4. Profile: identity, SSH keys, and a secrets bundle
tools/make-profile.sh --name default --user you --realname 'Your Name' \
    --email you@example.io --hostname compute1 --ssh-pub ~/.ssh/id_ed25519.pub \
    --secrets-dir ~/path/to/secrets          # or --from-mac on the control machine
# 5. Assemble the data partition (DESTROYS it) or refresh just the tree
tools/assemble-stick.sh     # first time, from macOS
tools/sync-stick.sh         # every later change
```

Profile flags (also in `stick/provision/profiles/example/profile.conf`):
`--nvidia` / `--cuda` / `--zerotier <network-id>` opt into the GPU and VPN
stand-up stages; `--no-claude`, `--no-sudo`, `--no-cache`, `--no-policy`
turn stages off. `--refresh-only` regenerates the seed and boot menu without
touching identity, keys, or credentials.

## Flows

- **Flow A (recommended): unattended.** Boot the stick, pick the server ISO
  entry, walk away. The install powers the machine off; leave the stick in
  and power back on; first boot completes provisioning. Details in
  [stick/README.md](stick/README.md).
- **Flow B: desktop/manual.** Boot the desktop ISO, install by hand, then
  `sudo bash <stick>/provision/bootstrap.sh` does everything else.

## Security model

- The stick carries an unencrypted secrets bundle per profile (model API
  keys, CLI auth). This is an explicit owner decision for an internal
  two-machine tool; the tradeoff is documented in `stick/README.md`. If a
  stick is lost, rotate those credentials.
- Nothing secret is committed here: profiles, real router configs, the
  policy file, generated seeds (which contain a password hash), binaries and
  ISOs are all `.gitignore`d. `tools/make-profile.sh` and the committed
  example files show the exact shapes you need to provide.
- SSH is key-only; the initial console password lives only in the profile.

## Development

```sh
shellcheck -S warning stick/provision/bootstrap.sh tools/*.sh
docker build -t ventoy-provision-tests tools/tests
docker run --rm --privileged -v "$PWD:/work" -w /work ventoy-provision-tests \
    bash -c 'python3 tools/tests/test_bootstrap.py && python3 tools/tests/test_latehook.py'
```

The tests run the real provisioner against mocked binaries in a disposable
Ubuntu container; no profile or credential in the suite is real.
