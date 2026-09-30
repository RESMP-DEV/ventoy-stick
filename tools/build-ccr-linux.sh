#!/usr/bin/env bash
# Cross-build a static Linux x86_64 ccr-rust for the provisioning stick.
# Portable: ROOT resolves from this script's location; set CCR_SOURCE_DIR to the
# ccr-rust checkout (default ~/ccr-rust). Requires: rustup with the
# x86_64-unknown-linux-musl target, zig (0.14+), rsync.
#
# Uses zig as the musl cross C toolchain. The staging copy gets two edits:
#   - reqwest switched to rustls (vendored OpenSSL + zig produced empty stub
#     archives twice; src/ has no direct TLS usage)
# The upstream repo and any installed ccr-rust binary are never touched.
#
# Known-good on: macOS arm64 (Sequoia/Tahoe, zig 0.16).
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
CCR_SOURCE_DIR=${CCR_SOURCE_DIR:-$HOME/ccr-rust}
ZIG_BIN=$(command -v zig || echo /opt/homebrew/bin/zig)
SRC=$ROOT/build/ccr-rust
TC=$ROOT/build/tc

[ -d "$CCR_SOURCE_DIR" ] || { echo "ccr-rust source not found: $CCR_SOURCE_DIR (set CCR_SOURCE_DIR)" >&2; exit 1; }
command -v "$ZIG_BIN" >/dev/null || { echo "zig not found (install: brew install zig)" >&2; exit 1; }
rustup target list --installed | grep -q x86_64-unknown-linux-musl || rustup target add x86_64-unknown-linux-musl

mkdir -p "$TC"
# zig cc wrappers: drop Rust-style --target triples (zig rejects
# 'x86_64-unknown-linux-musl'; it wants 'x86_64-linux-musl').
for COMP in cc c++; do
cat > "$TC/zig-$COMP" <<EOF
#!/bin/sh
args=""
expect_triple=""
for a in "\$@"; do
    if [ -n "\$expect_triple" ]; then
        case "\$a" in
            x86_64-unknown-linux-*) expect_triple=""; continue ;;
        esac
    fi
    case "\$a" in
        --target=x86_64-unknown-linux-*) continue ;;
        -target|-target=*) expect_triple=1; continue ;;
    esac
    args="\$args \$(printf '%s ' "\$a" | sed -e 's/--target=x86_64-unknown-linux-musl//' -e 's/--target=x86_64-unknown-linux-gnu//')"
done
exec "$ZIG_BIN" $COMP -target x86_64-linux-musl \$args
EOF
done
cat > "$TC/zig-ar" <<EOF
#!/bin/sh
exec "$ZIG_BIN" ar "\$@"
EOF
chmod +x "$TC"/*

# staging copy of the router source (upstream untouched)
mkdir -p "$ROOT/build"
[ -d "$SRC" ] || rsync -a --exclude target --exclude .git "$CCR_SOURCE_DIR"/ "$SRC"/
cd "$SRC"
# start from the pristine Cargo.toml every run (staging copy may carry older edits)
install -m 644 "$CCR_SOURCE_DIR/Cargo.toml" "$SRC/Cargo.toml"
python3 - <<'EOF'
import pathlib, re
p = pathlib.Path("Cargo.toml")
s = p.read_text()
if "rustls-tls" not in s:
    s2 = re.sub(r'^openssl = "=0\.10\.80".*$\n?', '', s, flags=re.M)
    s2 = re.sub(
        r'^reqwest = \{ version = "0\.12", features = \["json", "stream"\] \}$',
        'reqwest = { version = "0.12", default-features = false, features = ["json", "stream", "rustls-tls"] }',
        s2,
        flags=re.M,
    )
    assert s2 != s, "expected lines not found"
    p.write_text(s2)
EOF

export PATH="$TC:$HOME/.cargo/bin:/usr/bin:/bin:/usr/sbin:/sbin"
unset RUSTC_WRAPPER CARGO_BUILD_RUSTC_WRAPPER 2>/dev/null || true
export CC_x86_64_unknown_linux_musl="$TC/zig-cc"
export CXX_x86_64_unknown_linux_musl="$TC/zig-cxx"
export AR_x86_64_unknown_linux_musl="$TC/zig-ar"
export CARGO_TARGET_X86_64_UNKNOWN_LINUX_MUSL_LINKER="$TC/zig-cc"
export CARGO_TARGET_DIR="$SRC/target"
# let zig provide the musl crt; rust's self-contained rcrt1.o duplicates _start with zig's crt1.o
export RUSTFLAGS="-C link-self-contained=no"

cargo build --release --target x86_64-unknown-linux-musl
file "$SRC/target/x86_64-unknown-linux-musl/release/ccr-rust"
mkdir -p "$ROOT/stick/provision/bin"
cp "$SRC/target/x86_64-unknown-linux-musl/release/ccr-rust" "$ROOT/stick/provision/bin/ccr-rust"
shasum -a 256 "$ROOT/stick/provision/bin/ccr-rust" 2>/dev/null || sha256sum "$ROOT/stick/provision/bin/ccr-rust"
