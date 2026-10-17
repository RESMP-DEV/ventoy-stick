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
3. Prints `SETUP_EXIT_CODE=0` on success. Reopen Windows Terminal afterward so
   refreshed PATH entries take effect.

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
