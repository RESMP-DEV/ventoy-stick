# 2026-10-17 Windows Codex/CCR robustness repair

**Agent:** Codex
**Base state:** local `master` at `b939ecb`, two commits ahead of origin and
not pushed

## Diagnosis

The first Windows section did **not** install `ccr-rust`, Codex, credentials,
launch aliases, listeners, healthchecks, or setup logs. It installed baseline
tools and copied policy files. No Windows setup log or receipt from the user's
attempt was present on the USB section, so the reported runtime failure could
not be reconstructed from artifacts. The missing CCR/Codex payload is a direct,
verified explanation for `ccr-rust` and the Codex alias not working.

The original setup also used forceful policy writes. It could replace an
existing global policy instead of yielding to a user's own workspace/global
policy. That design was wrong for this stick.

## Repairs

- Added a pinned self-contained Windows payload:
  - Codex `rust-v0.154.0`, asset `codex-x86_64-pc-windows-msvc.exe`,
    SHA-256 `be96b992178b1e467c225800da0d65f2c86d5eba1ef0b14632f65db381cbdfde`
  - `ccr-rust` built from RESMP-DEV commit `3d07a5a`, SHA-256
    `12e08cd0b29a60c1b0584b15f8edda9afa51ef840b58b276890c4095989a835f`
- Added `tools/build-ccr-windows.sh`, using mingw-w64, sccache, rustls, and a
  staged portable pyright-link patch. Optional sindexer support is omitted from
  the Windows router build because its current pyright workspace implementation
  uses Unix-only symlinks.
- Setup now installs into `%LOCALAPPDATA%\VentoyTools\bin`, prepends that user
  PATH directory, verifies alias resolution, and installs:
  - `codex-ccr.cmd`
  - `ccr-main.cmd`
  - `ccr-glm-workers.cmd`
  - `ccr-healthcheck.cmd`
  - `ccr-smoke.cmd`
- `codex-ccr.cmd` uses the dedicated `CODEX_HOME`
  `%USERPROFILE%\.codex-ccr`, starts the GLM listener when needed, and invokes
  Codex profile `ccr`.
- CCR uses `%USERPROFILE%\.ccr-ventoy` and never repoints or overwrites the
  user's `.claude-code-router` directory.
- Policy installation now only fills absent targets. Existing `AGENTS.md`,
  `.codex\AGENTS.md`, `.claude\CLAUDE.md`, `.codex`, and
  `.claude-code-router` state is preserved. A workspace policy therefore keeps
  precedence and is never replaced by the stick.
- Default profile credentials are extracted into dedicated ACL-restricted homes.
  Credential values are never logged.
- The setup launches both CCR listeners, installs per-user Startup shortcuts,
  validates configs through launchers after credential injection, and runs the
  authorized GLM model-catalog healthcheck.
- `SETUP.bat -Smoke` opt-in runs a real Codex completion and requires an exact
  generated final marker. It is not run by default because it spends a model
  request.
- Setup records step timings and outcomes to
  `%LOCALAPPDATA%\VentoyTools\logs\setup-<timestamp>.log` plus
  `setup-latest.json`. Both success and failure write the summary. Redacted logs
  are copied to `windows-setup\logs\` on the USB when writable.
- Each CCR listener writes separate stdout/stderr logs and a PID file. Listener
  stop/restart refuses to kill a process outside the installed CCR binary.
- Future stick syncs preserve Windows runtime logs and generated Hello rollback
  `.reg` files.

## Validation

All listed commands exited `0` unless explicitly marked otherwise.

- Pinned Codex asset downloaded from the official release and matched the GitHub
  API digest and local SHA-256.
- `tools/build-ccr-windows.sh`: completed twice with the final source-date
  settings and produced the same CCR SHA-256 above. `file` identified a PE32+
  x86-64 Windows console executable.
- PowerShell 7.6.7 parser, from a portable copy under the AlphaHENG cache,
  parsed all six `.ps1` files with zero syntax errors.
- `python3 tools/tests/test_windows_setup.py`: 8 tests passed.
- `bash -n tools/build-ccr-windows.sh tools/sync-stick.sh`: passed.
- `shellcheck -S warning tools/build-ccr-windows.sh tools/sync-stick.sh`: passed
  after separating the source-date assignment/export.
- `git -c core.whitespace=cr-at-eol diff --check`: passed.
- Portable success-path execution with tools/CCR skipped: exited 0, summary
  `passed`, and copied redacted logs.
- Portable forced policy failure: exited 1, summary `failed`, current step
  `policy`, failed step `policy`, and still wrote both local and stick log
  summaries.
- Secret-pattern scan over textual changes found no real bearer/API key.
- Final `tools/sync-stick.sh`: `SYNC_DONE`; 51 manifest entries.

## Machine/environment changes

- Installed Homebrew `mingw-w64 14.0.0_3` plus its `isl` and `libmpc`
  dependencies to provide the native Windows cross-linker.
- Cached portable PowerShell 7.6.7 under
  `/Users/kearm/.cache/alphaheng/tools/pwsh-7.6.7`; no system PowerShell
  installation was changed.

## Non-claims

- No Windows host executed the final setup, listeners, healthcheck, or smoke.
- No real model completion was spent from this Mac.
- The `ccr-rust` build emits one non-fatal Windows-only unused-import warning
  from `pyright_workspace.rs`.
- Windows ARM64 is accepted only through the operating system's x86_64
  emulation; no ARM64 Windows host was available to test.
