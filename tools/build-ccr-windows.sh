#!/usr/bin/env bash
# Cross-build the pinned RESMP-DEV ccr-rust router for Windows x86_64 with
# mingw-w64. Zig cannot currently provide the MinGW import libraries.
# The destination is self-contained: SETUP.bat installs this exe instead of
# asking a newly provisioned Windows box to compile Rust code.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
CCR_SOURCE_DIR=${CCR_SOURCE_DIR:-$HOME/ccr-rust}
CCR_REVISION=${CCR_REVISION:-3d07a5a}
SRC=$ROOT/build/ccr-rust-windows
OUT=$ROOT/stick/windows-setup/bin
MINGW_BIN=${MINGW_BIN:-/opt/homebrew/opt/mingw-w64/bin}

[ -d "$CCR_SOURCE_DIR" ] || { echo "ccr-rust source not found: $CCR_SOURCE_DIR" >&2; exit 1; }
command -v x86_64-w64-mingw32-gcc >/dev/null || { echo "x86_64-w64-mingw32-gcc not found (brew install mingw-w64)" >&2; exit 1; }
command -v x86_64-w64-mingw32-dlltool >/dev/null || { echo "x86_64-w64-mingw32-dlltool not found" >&2; exit 1; }
rustup target list --installed | grep -q '^x86_64-pc-windows-gnu$' \
    || rustup target add x86_64-pc-windows-gnu

mkdir -p "$SRC" "$OUT"

git -C "$CCR_SOURCE_DIR" archive "$CCR_REVISION" | tar -x -C "$SRC"
cd "$SRC"
python3 - <<'EOF'
import pathlib
pyright = pathlib.Path("src/mcp/tools/pyright.rs")
s = pyright.read_text()
if "fn portable_link(" not in s:
    marker = "impl PyrightTool {"
    helper = '''fn portable_link(src: &Path, dst: &Path) -> Result<()> {
    #[cfg(unix)]
    {
        std::os::unix::fs::symlink(src, dst)
            .with_context(|| format!("failed to symlink {} to {}", src.display(), dst.display()))?;
    }
    #[cfg(windows)]
    {
        if src.is_dir() {
            std::fs::create_dir_all(dst)
                .with_context(|| format!("failed to create dir: {}", dst.display()))?;
            for entry in (std::fs::read_dir(src)?).flatten() {
                let child_dst = dst.join(entry.file_name());
                if entry.file_type()?.is_dir() {
                    portable_link(&entry.path(), &child_dst)?;
                } else {
                    std::fs::copy(entry.path(), child_dst)?;
                }
            }
        } else {
            std::fs::copy(src, dst)?;
        }
    }
    Ok(())
}

'''
    s = s.replace(marker, helper + marker, 1)
s = s.replace("std::os::unix::fs::symlink(&pyright_config, ws_path.join(\"pyrightconfig.json\"))", "portable_link(&pyright_config, &ws_path.join(\"pyrightconfig.json\"))")
s = s.replace("std::os::unix::fs::symlink(&src, &dst)", "portable_link(&src, &dst)")
s = s.replace("std::os::unix::fs::symlink(entry.path(), &child_dst).ok();", "portable_link(&entry.path(), &child_dst).ok();")
pyright.write_text(s)

p = pathlib.Path("Cargo.toml")
s = p.read_text()
re = __import__('re')
s = re.sub(r'^openssl\s*=.*$\n?', '', s, count=1, flags=re.M)
if "rustls-tls" not in s:
    s = s.replace(
        'reqwest = { version = "0.12", features = ["json", "stream"] }',
        'reqwest = { version = "0.12", default-features = false, features = ["json", "stream", "rustls-tls"] }',
    )
    p.write_text(s)
EOF

export PATH="$MINGW_BIN:$HOME/.cargo/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"
export CC_x86_64_pc_windows_gnu=x86_64-w64-mingw32-gcc
export CXX_x86_64_pc_windows_gnu=x86_64-w64-mingw32-g++
export AR_x86_64_pc_windows_gnu=x86_64-w64-mingw32-ar
export CARGO_TARGET_X86_64_PC_WINDOWS_GNU_LINKER=x86_64-w64-mingw32-gcc
export CARGO_TARGET_DIR="$SRC/target"
export CARGO_INCREMENTAL=0
export RUSTC_WRAPPER=${RUSTC_WRAPPER:-sccache}
source_date_epoch=$(git -C "$CCR_SOURCE_DIR" show -s --format=%ct "$CCR_REVISION")
export SOURCE_DATE_EPOCH=$source_date_epoch
export ZERO_AR_DATE=1
# sindexer's current pyright workspace code uses Unix-only symlinks. The router
# does not need that optional feature; retain dashboard + gp support.
cargo build --release --target x86_64-pc-windows-gnu \
    --no-default-features --features dashboard,gp --bin ccr-rust
file "$SRC/target/x86_64-pc-windows-gnu/release/ccr-rust.exe"
cp "$SRC/target/x86_64-pc-windows-gnu/release/ccr-rust.exe" "$OUT/ccr-rust-x86_64.exe"
ccr_hash=$(shasum -a 256 "$OUT/ccr-rust-x86_64.exe" | cut -d' ' -f1)
checksum_tmp="$OUT/BINARIES.sha256.tmp"
touch "$OUT/BINARIES.sha256"
awk -v hash="$ccr_hash" '$2 == "ccr-rust-x86_64.exe" { $1 = hash } { print }' \
    "$OUT/BINARIES.sha256" > "$checksum_tmp"
mv "$checksum_tmp" "$OUT/BINARIES.sha256"
printf 'ccr source=%s revision=%s\n' "$CCR_SOURCE_DIR" "$CCR_REVISION"
printf 'ccr sha256=%s\n' "$ccr_hash"
