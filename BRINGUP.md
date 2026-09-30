# Compute-machine bring-up runbook (post-Ventoy)

What the stick already does, end to end:

1. Unattended Ubuntu 26.04.1 Server install (autoinstall; ends powered off).
2. The seed itself writes the first-boot retry unit AND the passwordless
   sudoers fragment into the fresh system (both pure `/target` writes).
3. First boot (stick inserted) runs `provision-retry.service`: binaries,
   secrets, baseline tools, and the full stand-up layer —
   - passwordless sudo (visudo-validated fragment in `/etc/sudoers.d/`)
   - build-cache wiring (`~/.cargo/config.toml` absolute sccache wrapper,
     `/etc/profile.d/00-build-cache.sh`, `~/.config/ccache/ccache.conf`,
     `/usr/local/bin/sccache` symlink)
   - policy files (`~/AGENTS.md`, `~/.codex/AGENTS.md`,
     `~/.claude/CLAUDE.md` stub) from `files/AGENTS-core.md`
   - Claude Code (native installer) + `~/.local/bin/claude-ccr` launcher +
     `~/.claude/settings.json` routing
   - NVIDIA driver (`nvidia-driver-595-open`), persistence daemon enabled,
     nvtop, optional CUDA toolkit
   - ZeroTier install + `zerotier-cli join` of the profile's network
   - CCR listeners (`127.0.0.1:3456` main, `127.0.0.1:3457` glm-workers)
4. Acceptance smokes: a real Codex turn through CCR GLM and a real Claude
   turn through ccr-main, each checked against an exact marker.

The completion verdict now looks like:

```
RESULT: mode=full baseline=ok secrets=ok services=ok health=ok smoke=ok \
  sudo=ok caches=ok policy=ok claude=ok claude_smoke=ok nvidia=ok cuda=ok zt=ok
```

Any `failed`/`missing` status withholds `/root/BOOTSTRAP-OK`, so the next
boot with the stick inserted retries everything incomplete (the unit is
conditional on that marker; each stage is idempotent). Check with:

```sh
sudo systemctl status provision-retry.service
sudo tail -100 /var/log/ventoy-bootstrap.log
sudo systemctl restart provision-retry.service   # after fixing something
```

The first-boot window is 75 minutes (baseline up to 30, NVIDIA + CUDA fit
inside the same run).

Everything below is the small manual remainder, field-tested on the
2026-09-29 re-image of the compute machine. Placeholders: `<lan-ip>`,
`<user>`, `<host-alias>` (your ssh config alias for the box). Worked examples
assume that alias resolves; adapt per machine.

## 1. Mac-side connection repair (after any re-image)

A re-image changes host keys; do not trust until fresh-install markers check out.

```bash
ssh-keyscan <lan-ip>   # expect a NEW ED25519 fingerprint, hostname = compute
cp ~/.ssh/known_hosts ~/.ssh/known_hosts.bak-$(date +%Y%m%d)
sed -i '' '/^<host-alias> /d;/^<lan-ip> /d' ~/.ssh/known_hosts
```

Then reconnect and verify fresh-install markers before trusting:
`hostnamectl`, `uname -r` (kernel newer than the old install), and the
provision-retry verdict line above. Do not `ls /root/BOOTSTRAP-OK` over SSH;
/root is 0700 and SSH runs as the provisioned user, so it always looks absent.

USB-Ethernet re-enumeration: if the ssh alias ProxyCommand binds a dead
interface (`Connection closed by UNKNOWN port 65535`), find the live one
(`ifconfig | grep -B3 'inet 192.168'`) and rebind the alias's interface
(`-b en13` was rebound to `-b en15` once; check `nc -b <iface> -G 2 -z`).

## 2. ZeroTier authorization (manual by design)

The box joins the network itself; the node sits `ACCESS_DENIED` until you
authorize it in ZeroTier Central. Find the new node id, authorize, then
watch it flip OK and get a managed IP:

```bash
ssh compute 'sudo zerotier-cli info; sudo zerotier-cli listnetworks'
```

Then repoint the Mac ssh alias ZT fallback to the new managed IP (the old
one dies with the old node identity). The alias ProxyCommand tries LAN
first, ZT second. Verify both paths.

## 3. Claude Code model routing notes

- `claude-ccr` routes every tier through the box's ccr-main (3456) with a
  `[1m]` context suffix on the model id. The `[1m]` suffix must be on the
  model string; env vars alone do not unlock the 1M window.
- If the box's ccr build predates the claude-* alias support, keep the
  client-side `[1m]` suffix form (what the provisioner writes).
- Smoke both agents (exact marker, not just exit 0):

```bash
ssh compute '~/.local/bin/claude-ccr -p "reply with exactly CLAUDE-CCR-OK"'
ssh compute '~/.local/bin/codex exec "reply with exactly CODEX-OK"'
```

Non-login SSH has no `~/.profile` PATH; use full `~/.local/bin/...` paths.

## 4. Final verification sweep

```bash
ssh compute 'hostnamectl | grep -E "Operating System|Kernel"; sudo -n true && echo sudo-ok'
ssh compute 'nvidia-smi --query-gpu=name,driver_version,persistence_mode --format=csv; nvcc --version | tail -2'
ssh compute 'systemctl --user is-active ccr-main ccr-glm-workers; curl -sf http://127.0.0.1:3456/health | head -c 200; echo'
ssh compute 'ccache -p | grep -E "max_size|inode_cache"; sccache --show-stats | grep -E "Max cache size|Cache location"'
ssh compute 'zerotier-cli listnetworks | tail -1'
ssh compute 'head -3 ~/AGENTS.md; ls ~/.claude/settings.json ~/.local/bin/claude-ccr'
```

All green means the machine is remote-ready for bounded SSH compute work.
Remember the machine-role rules: the box is execution only; Git, credentials,
planning, and acceptance stay on the control machine.

## 5. Gotchas (learned the hard way, 2026-09-29)

These are baked into the provisioner now; kept here because they will bite
any manual repair:

- sccache NEVER caches `--crate-type bin` crates (the linker step is outside
  its interception). A `cargo new` hello-world BIN shows 0 hits and
  `Non-cacheable reasons: crate-type/missing input` forever. Prove caching
  with a LIB crate double build instead.
- Ubuntu 26.04 `pam_env` does NOT inject `/etc/environment` into ssh
  sessions (UsePAM yes, pam_env.so present, vars still absent). The
  provisioner therefore wires `~/.cargo/config.toml` and `/etc/profile.d/`
  and never relies on `/etc/environment`.
- sccache stats flags: `--show-stats` / `--show-adv-stats` (no `--stats`);
  `--zero-stats` resets. A server started by hand without
  `SCCACHE_CACHE_SIZE` in scope defaults to 10 GiB.
- The NVIDIA `-open` kernel modules are unsigned: Secure Boot must be OFF or
  they will not load (bootstrap refuses to pretend when `mokutil` says on).
- `nvidia-persistenced.service` is a static unit (no `[Install]`): enabled
  via the `multi-user.target.wants` symlink, which the provisioner creates.
- CUDA toolkit install (`nvidia-cuda-toolkit`) takes several minutes; the
  profile can skip it (`ENABLE_CUDA=0`) when only GPU serving is needed.

## 6. Out of stick scope

Compute-side services that were stood up by hand on the first machine and
are deliberately NOT in the bootstrap: the self-hosted code-search stack
(embedding server + vector DB) and the distributed filesystem deployment.
Provision those per their own project docs when a new machine needs them.
