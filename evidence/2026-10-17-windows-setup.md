# 2026-10-17 Windows operator section

**Agent:** Codex
**Base revision:** `5225f7c` (working tree intentionally dirty during this task)
**Scope:** Added and synced a Windows-native operator section to the attached Ventoy USB drive. This receipt does not claim Windows runtime execution.

## What changed

- Added `stick/windows-setup/SETUP.bat` plus `setup.ps1`.
- Added the staged local-account password and Windows Hello replacement scripts:
  `SET-PASSWORD.bat`, `set-password.ps1`, `DISABLE-WINDOWS-HELLO.bat`, and
  `disable-windows-hello.ps1`.
- Added Windows-specific instructions and static tests.
- Routed the new section into the repository and stick documentation.
- The Windows payload never executes the Linux binaries and never copies or
  unpacks `secrets.tar`.

## Windows Hello safety design

`SET-PASSWORD.bat` is deliberately run before `DISABLE-WINDOWS-HELLO.bat`. The
first stage refuses non-local organization/Microsoft accounts, prompts twice,
sets the enabled local account password, preserves the prior password-sign-in
registry value in a rollback `.reg`, and exposes password sign-in. The user
must prove that password at Windows+L. The second stage requires the typed
confirmation `PASSWORD-TESTED`, verifies password sign-in is exposed, preserves
the previous credential-provider exclusion policy in a rollback `.reg`, and
only then excludes the documented PIN, fingerprint, and facial-recognition
providers. Existing enrollments are not deleted by policy and must be removed
in Settings after password sign-in is proven.

## Validation and deployment evidence

All commands below exited `0` unless stated otherwise.

- `python3 tools/tests/test_windows_setup.py`: 4 tests passed.
- `git diff --check`: passed.
- Batch payload checked as ASCII with CRLF line endings and no patch markers.
- All 17 `winget` package identifiers were resolved against the live
  `microsoft/winget-pkgs` manifest tree. `Rclone.Rclone` and
  `mcmilk.7zip-zstd` replaced two intuitive-but-wrong IDs.
- `tools/sync-stick.sh`: `SYNC_DONE`; 39 manifest entries.
- `diff -qr stick/windows-setup /Volumes/Ventoy/windows-setup`: no differences.
- `cd /Volumes/Ventoy && shasum -a 256 -c MANIFEST.sha256`: all 39 entries
  `OK`, including the Windows section, ISOs, real profile, and secrets bundle.

The destination was live-verified as external USB `/dev/disk12`, volume name
`Ventoy`, exFAT, mounted writable at `/Volumes/Ventoy`.

## Non-claims

- No Windows host executed the batch or PowerShell files.
- PowerShell parser/runtime validation was unavailable on this Mac (`pwsh` and
  the Docker daemon were not available).
- No account password was changed and no Windows registry value was changed.
- Cloud/organization-managed accounts and existing Hello enrollments remain
  governed by their owning service and Settings UI respectively.
