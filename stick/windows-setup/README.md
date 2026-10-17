# Windows operator setup

This is the Windows-native counterpart to the Linux provisioner. It does not
execute the Linux binaries under `provision/bin/`, does not unpack
`provision/profiles/*/secrets.tar`, and does not copy credentials from the
Ventoy stick.

## Install the Windows environment

Open this folder in Windows and double-click `SETUP.bat`.

The normal path:

1. Installs the baseline command-line tools with `winget`: 7-Zip, Git, GitHub
   CLI, Python 3.12, uv, Rust, ripgrep, fd, bat, delta, jq, yq, CMake, Ninja,
   just, rclone, and 7-Zip-zstd for Zstandard support.
2. Installs the stick's real `provision/files/AGENTS-core.md` as:
   - `%USERPROFILE%\AGENTS.md`
   - `%USERPROFILE%\.codex\AGENTS.md`
   - `%USERPROFILE%\.claude\CLAUDE.md`, an `@~/AGENTS.md` import stub
3. Installs pinned native Windows binaries:
   - Codex CLI `rust-v0.154.0`
   - RESMP-DEV `ccr-rust` built from `3d07a5a`
4. Unpacks the default profile credentials into dedicated homes:
   - `%USERPROFILE%\.codex-ccr`
   - `%USERPROFILE%\.ccr-ventoy`
5. Installs these aliases under `%LOCALAPPDATA%\VentoyTools\bin`:
   - `codex-ccr`, which starts CCR if needed, sets the dedicated Codex home,
     and runs profile `ccr`
   - `ccr-main`, `ccr-glm-workers`, and `ccr-healthcheck`
   - `ccr-smoke`
6. Validates both CCR configs, starts both listeners, installs per-user Startup
   shortcuts, and runs the authorized model-catalog healthcheck.
7. Prints `SETUP_EXIT_CODE=0` on success. Reopen Windows Terminal afterward so
   refreshed PATH entries take effect.

A real completion smoke is opt-in because it spends a model request:

```bat
SETUP.bat -Smoke
```

The smoke requires the Codex final message to equal a generated marker exactly.

Setup writes detailed logs to:

- `%LOCALAPPDATA%\VentoyTools\logs\setup-<timestamp>.log`
- `%LOCALAPPDATA%\VentoyTools\logs\setup-latest.json`
- `windows-setup\logs\` on the Ventoy drive, when that volume is writable

Command output is redacted for API keys, bearer tokens, and common token field
names before it reaches these logs. Each CCR listener also writes
`ccr-main.out.log`, `ccr-main.err.log`, `ccr-workers.out.log`, and
`ccr-workers.err.log` in the same local log directory.

Policy handling is deliberately non-destructive. Existing `AGENTS.md`,
`.codex\AGENTS.md`, `.claude\CLAUDE.md`, `.codex`, and
`.claude-code-router` files are never replaced. The CCR Codex installation
uses a separate `.codex-ccr` home, so a repository/workspace `AGENTS.md`
remains the controlling local policy and your existing global configuration is
not repointed.

Use `SETUP.bat -SkipTools` for policy only, or `SETUP.bat -SkipPolicy` for
tools only. The public Git checkout contains only the example policy; the
physical stick contains the private real policy.

## Replace Windows Hello with a local account password

This is deliberately a two-stage procedure. Do not combine the stages before
the password has successfully unlocked the machine.

### Stage 1: set and prove the password

Right-click `SET-PASSWORD.bat` and choose **Run as administrator**.

The script accepts only an enabled local Windows account. It rejects domain,
Microsoft, and other organization-backed accounts because their passwords
belong to an external service. It prompts twice for the new local password,
never displays or saves it, sets that password, writes a rollback `.reg` file
that preserves the prior password-sign-in setting, and sets
`DevicePasswordLessBuildVersion` to `0` so password sign-in is visible.

Immediately press Windows+L and unlock with the new password. This test is the
gate for Stage 2. If it fails, sign back in with a currently working method and
recover the local password through another local administrator account.

### Stage 2: disable Windows Hello sign-in providers

After the password test succeeds, right-click
`DISABLE-WINDOWS-HELLO.bat` and choose **Run as administrator**. It asks you
to type `PASSWORD-TESTED`, verifies that password sign-in is exposed, writes a
rollback `.reg` file preserving any existing exclusion policy, and excludes
these Microsoft-documented credential providers:

- Windows Hello PIN: `{D6886603-9D2F-4EB2-B667-1971041FA96B}`
- Fingerprint: `{BEC09223-B018-416D-A0AC-523971B639F5}`
- Facial recognition: `{8AF662BF-65A0-4D0A-A540-A338A999D36F}`

Press Windows+L again and prove password unlock still works. If it does not,
sign in with a recovery method and double-click the generated
`hello-rollback-*.reg` file to restore the previous provider policy. Windows
may require sign-out, reboot, or policy refresh before provider changes are
visible.

Policy does not delete enrolled credentials. Once password sign-in is proven,
open Settings, Accounts, Sign-in options and remove old PIN, fingerprint, and
face enrollments if Windows still lists them.

For a Microsoft or organization-managed account, change its password through
the owning service and apply that service's Windows Hello policy. The local
admin scripts here are intentionally inapplicable.
