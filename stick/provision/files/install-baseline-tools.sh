#!/usr/bin/env bash
# Install and verify AlphaHENG's required operator/agent CLI baseline.
#
# Default mode installs missing tools. Use --check for verification only.

set -euo pipefail

MODE="install"
REQUIRED_TOOLS=(
    uv ruff ty pixi hf hfd
    ccache sccache cmake ninja just cargo-audit cargo-deny
    pip-audit osv-scanner
    rg fd bat delta jq yq
    shellcheck shfmt actionlint zizmor hyperfine
    gh git-lfs aria2c rclone zstd mosh
)

usage() {
    cat <<'EOF'
Usage: scripts/install-baseline-tools.sh [--check]

Required tools:
  Python/environment:
    uv ruff ty pixi hf

  Native build/cache:
    ccache sccache cmake ninja just

  Dependency security:
    cargo-audit cargo-deny pip-audit osv-scanner

  Code/workflow validation:
    rg fd bat delta jq yq shellcheck shfmt actionlint zizmor hyperfine

  Artifact/remote transport:
    gh git-lfs hfd aria2c rclone zstd mosh

Environment:
  ALPHAHENG_BASELINE_APT_UPDATE=1  Run apt-get update before apt installs.
  HFD_CLI_SOURCE=/path/or/uv-git-url  Override the independent hfd package source.
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --check)
            MODE="check"
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "Unknown option: $1" >&2
            usage >&2
            exit 2
            ;;
    esac
done

export PATH="$HOME/.local/bin:$HOME/.pixi/bin:$HOME/.cargo/bin:/opt/homebrew/bin:/usr/local/bin:${PATH:-}"

log() { printf '[baseline-tools] %s\n' "$1"; }
warn() { printf '[baseline-tools][WARN] %s\n' "$1" >&2; }

have() {
    command -v "$1" >/dev/null 2>&1
}

missing() {
    ! have "$1"
}

have_mikefarah_yq() {
    have yq && yq --version 2>/dev/null | grep -Eq 'mikefarah/yq|version v?4\.'
}

tool_available() {
    if [[ "$1" == "yq" ]]; then
        have_mikefarah_yq
    else
        have "$1"
    fi
}

sudo_cmd() {
    if [[ "$(id -u)" -eq 0 ]]; then
        "$@"
    else
        sudo "$@"
    fi
}

# all curl invocations get bounded retries/timeouts so an unattended run can
# never hang forever on a stalled connection
curl() {
    command curl --retry 3 --retry-delay 2 --connect-timeout 15 --max-time 300 "$@"
}

apt_install_if_missing() {
    local cmd="$1"
    local pkg="$2"
    if have "$cmd"; then
        return 0
    fi
    if ! have apt-get; then
        return 1
    fi
    log "apt install $pkg"
    sudo_cmd env DEBIAN_FRONTEND=noninteractive \
        apt-get install -y --no-install-recommends -o Acquire::Retries=3 "$pkg"
}

cargo_install_if_missing() {
    local cmd="$1"
    local crate="$2"
    if have "$cmd"; then
        return 0
    fi
    if ! have cargo; then
        return 1
    fi
    log "cargo install --locked $crate"
    cargo install --locked "$crate"
}

ensure_uv() {
    if have uv; then
        return 0
    fi
    if ! have curl; then
        warn "curl is required to install uv"
        return 1
    fi
    log "install uv"
    curl -LsSf https://astral.sh/uv/install.sh | sh
    export PATH="$HOME/.local/bin:$PATH"
}

ensure_uv_tool() {
    local tool="$1"
    if have "$tool"; then
        return 0
    fi
    ensure_uv || return 1
    log "uv tool install $tool@latest"
    uv tool install "$tool@latest"
    export PATH="$HOME/.local/bin:$PATH"
}

ensure_pip_audit() {
    if have pip-audit; then
        return 0
    fi
    ensure_uv || return 1
    log "uv tool install --python 3.12 pip-audit@latest"
    # Callers use `ensure_pip_audit || warn`, which suppresses errexit inside
    # this function; propagate the install failure explicitly so the warning
    # actually fires instead of falling through to a successful export.
    uv tool install --python 3.12 pip-audit@latest || return 1
    export PATH="$HOME/.local/bin:$PATH"
}

ensure_pixi() {
    if have pixi; then
        return 0
    fi
    if have brew; then
        log "brew install pixi"
        brew install pixi
        return 0
    fi
    if ! have curl; then
        warn "curl is required to install pixi"
        return 1
    fi
    log "install pixi"
    curl -fsSL https://pixi.sh/install.sh | bash
    export PATH="$HOME/.pixi/bin:$PATH"
}

ensure_hf() {
    if have hf; then
        return 0
    fi
    ensure_uv || return 1
    log "install Hugging Face CLI with uv"
    # Minimal Server does not include python3-venv. uv creates the environment
    # directly, without the external installer's undeclared venv dependency.
    uv tool install huggingface_hub || return 1
    export PATH="$HOME/.local/bin:$PATH"
}

ensure_hfd_cli() {
    local script_dir repo_root source ssh_path
    if have hfd; then
        return 0
    fi
    ensure_uv || return 1
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
    repo_root="$(cd "$script_dir/.." && pwd -P)"
    source="${HFD_CLI_SOURCE:-$(dirname "$repo_root")/hfd}"
    if [[ -z "${HFD_CLI_SOURCE:-}" && -f "$script_dir/wheels/hfd_cli-0.1.1-py3-none-any.whl" ]]; then
        source="$script_dir/wheels/hfd_cli-0.1.1-py3-none-any.whl"
    fi
    case "$source" in
        /*.whl) [[ -f "$source" ]] || return 1 ;;
        http://*.whl|https://*.whl|http://*.tar.gz|https://*.tar.gz|http://*.zip|https://*.zip) ;;
        http://*|https://*) source="git+$source" ;;
        *://*) ;;
        *@*:*|[[:alnum:]._-]*:*) source="git+ssh://${source/:/\/}" ;;
        *)
            if [[ ! -f "$source/pyproject.toml" ]]; then
                warn "independent hfd package not found at $source; set HFD_CLI_SOURCE"
                return 1
            fi
            ;;
    esac
    case "$source" in
        git+ssh://*)
            ssh_path="${source#git+ssh://}"
            ssh_path="${ssh_path#*@}"
            [[ "$ssh_path" == *@* ]] || warn "hfd source is not pinned to a revision: $source"
            ;;
        git+http://*|git+https://*)
            [[ "$source" == *@* ]] || warn "hfd source is not pinned to a revision: $source"
            ;;
    esac
    log "uv tool install hfd from $source"
    uv tool install "$source" || return 1
    export PATH="$HOME/.local/bin:$PATH"
    hash -r
}

ensure_homebrew_tools() {
    have brew || return 1
    local formulas=()
    local command_formula
    for command_formula in \
        ccache:ccache \
        sccache:sccache \
        cmake:cmake \
        ninja:ninja \
        just:just \
        cargo-audit:cargo-audit \
        cargo-deny:cargo-deny \
        osv-scanner:osv-scanner \
        rg:ripgrep \
        fd:fd \
        bat:bat \
        delta:git-delta \
        jq:jq \
        yq:yq \
        shellcheck:shellcheck \
        shfmt:shfmt \
        actionlint:actionlint \
        hyperfine:hyperfine \
        gh:gh \
        git-lfs:git-lfs \
        aria2c:aria2 \
        rclone:rclone \
        zstd:zstd \
        mosh:mosh; do
        local command="${command_formula%%:*}"
        local formula="${command_formula#*:}"
        if [[ "$command" == "yq" ]]; then
            have_mikefarah_yq || formulas+=("$formula")
        elif missing "$command"; then
            formulas+=("$formula")
        fi
    done
    if ((${#formulas[@]})); then
        log "brew install ${formulas[*]}"
        brew install "${formulas[@]}"
    fi
}

github_latest_tag() {
    local repository="$1"
    curl -fsSL "https://api.github.com/repos/$repository/releases/latest" \
        | jq -er '.tag_name'
}

version_at_least() {
    local current="$1"
    local required="$2"
    [[ -n "$current" ]] && [[ "$(printf '%s\n%s\n' "$required" "$current" | sort -V | tail -1)" == "$current" ]]
}

ensure_latest_ccache_linux() {
    local tag version current architecture asset temporary_dir installer
    local minisign_key="RWQX7yXbBedVfI4PNx6FLdFXu9GHUFsr28s4BVGxm4BeybtnX3P06saF"

    have curl && have jq && have minisign && have python3 || return 1
    tag="$(github_latest_tag ccache/ccache)"
    version="${tag#v}"
    current="$(ccache --version 2>/dev/null | awk 'NR == 1 {print $3}' || true)"
    if version_at_least "$current" "$version"; then
        return 0
    fi

    case "$(uname -m)" in
        x86_64) architecture="x86_64" ;;
        aarch64|arm64) architecture="aarch64" ;;
        *)
            warn "No upstream ccache binary mapping for $(uname -m); keeping the package version"
            return 0
            ;;
    esac

    asset="ccache-${version}-linux-${architecture}-glibc.tar.xz"
    temporary_dir="$(mktemp -d)"
    log "install upstream ccache $version with minisign verification"
    curl -fsSL \
        "https://github.com/ccache/ccache/releases/download/${tag}/${asset}" \
        -o "$temporary_dir/$asset"
    curl -fsSL \
        "https://github.com/ccache/ccache/releases/download/${tag}/${asset}.minisig" \
        -o "$temporary_dir/$asset.minisig"
    if ! minisign -P "$minisign_key" -Vm "$temporary_dir/$asset"; then
        rm -rf "$temporary_dir"
        warn "ccache minisign verification FAILED; refusing to install"
        return 1
    fi
    mkdir -p "$temporary_dir/unpack"
    tar -xf "$temporary_dir/$asset" -C "$temporary_dir/unpack"
    installer="$(find "$temporary_dir/unpack" -maxdepth 3 -type f -name install.sh -print -quit)"
    if [[ -z "$installer" ]]; then
        rm -rf "$temporary_dir"
        warn "ccache release did not contain install.sh"
        return 1
    fi
    "$installer" \
        --prefix="$HOME/.local" \
        --libexecdir="$HOME/.local/libexec"
    mkdir -p "$HOME/.local/libexec/ccache"
    local compiler
    for compiler in cc c++ gcc g++ clang clang++; do
        ln -sfn "$HOME/.local/bin/ccache" "$HOME/.local/libexec/ccache/$compiler"
    done
    rm -rf "$temporary_dir"
    hash -r
}

ensure_latest_sccache_linux() {
    local tag version current target asset temporary_dir binary expected actual

    have curl && have jq && have sha256sum || return 1
    tag="$(github_latest_tag mozilla/sccache)"
    version="${tag#v}"
    current="$(sccache --version 2>/dev/null | awk 'NR == 1 {print $2}' || true)"
    if version_at_least "$current" "$version"; then
        return 0
    fi

    case "$(uname -m)" in
        x86_64) target="x86_64-unknown-linux-musl" ;;
        aarch64|arm64) target="aarch64-unknown-linux-musl" ;;
        *)
            warn "No upstream sccache binary mapping for $(uname -m); keeping the package version"
            return 0
            ;;
    esac

    asset="sccache-${tag}-${target}.tar.gz"
    temporary_dir="$(mktemp -d)"
    log "install upstream sccache $version with SHA-256 verification"
    curl -fsSL \
        "https://github.com/mozilla/sccache/releases/download/${tag}/${asset}" \
        -o "$temporary_dir/$asset"
    curl -fsSL \
        "https://github.com/mozilla/sccache/releases/download/${tag}/${asset}.sha256" \
        -o "$temporary_dir/$asset.sha256"
    expected="$(tr -d '[:space:]' < "$temporary_dir/$asset.sha256")"
    actual="$(sha256sum "$temporary_dir/$asset" | awk '{print $1}')"
    if [[ "$actual" != "$expected" ]]; then
        rm -rf "$temporary_dir"
        warn "sccache SHA-256 verification failed"
        return 1
    fi
    tar -xzf "$temporary_dir/$asset" -C "$temporary_dir"
    binary="$(find "$temporary_dir" -type f -name sccache -print -quit)"
    if [[ -z "$binary" ]]; then
        rm -rf "$temporary_dir"
        warn "sccache release did not contain its binary"
        return 1
    fi
    install -m 0755 "$binary" "$HOME/.local/bin/sccache"
    rm -rf "$temporary_dir"
    hash -r
}

ensure_yq_linux() {
    local tag architecture asset temporary_dir hash_column
    if have_mikefarah_yq; then
        return 0
    fi
    have curl && have jq && have sha256sum || return 1
    case "$(uname -m)" in
        x86_64) architecture="amd64" ;;
        aarch64|arm64) architecture="arm64" ;;
        *)
            warn "No Mike Farah yq binary mapping for $(uname -m)"
            return 1
            ;;
    esac
    tag="$(github_latest_tag mikefarah/yq)"
    asset="yq_linux_${architecture}"
    temporary_dir="$(mktemp -d)"
    log "install Mike Farah yq $tag with SHA-256 verification"
    curl -fsSL \
        "https://github.com/mikefarah/yq/releases/download/${tag}/${asset}" \
        -o "$temporary_dir/$asset"
    curl -fsSL \
        "https://github.com/mikefarah/yq/releases/download/${tag}/checksums" \
        -o "$temporary_dir/checksums"
    curl -fsSL \
        "https://github.com/mikefarah/yq/releases/download/${tag}/checksums_hashes_order" \
        -o "$temporary_dir/checksums_hashes_order"
    # yq publishes filename-first rows containing many algorithms, not the
    # ordinary sha256sum format. Select SHA-256 using its companion column list.
    hash_column=$(awk '$0 == "SHA-256" {print NR + 1}' "$temporary_dir/checksums_hashes_order")
    [[ "$hash_column" =~ ^[0-9]+$ ]] || { rm -rf "$temporary_dir"; return 1; }
    if ! (
        cd "$temporary_dir"
        awk -v asset="$asset" -v column="$hash_column" '$1 == asset {print $column "  " $1}' checksums | sha256sum -c -
    ); then
        rm -rf "$temporary_dir"
        warn "yq SHA-256 verification FAILED; refusing to install"
        return 1
    fi
    install -m 0755 "$temporary_dir/$asset" "$HOME/.local/bin/yq"
    rm -rf "$temporary_dir"
    hash -r
}

ensure_actionlint_linux() {
    local tag version architecture asset checksums temporary_dir
    if have actionlint; then
        return 0
    fi
    have curl && have jq && have sha256sum || return 1
    case "$(uname -m)" in
        x86_64) architecture="amd64" ;;
        aarch64|arm64) architecture="arm64" ;;
        *)
            warn "No actionlint binary mapping for $(uname -m)"
            return 1
            ;;
    esac
    tag="$(github_latest_tag rhysd/actionlint)"
    version="${tag#v}"
    asset="actionlint_${version}_linux_${architecture}.tar.gz"
    checksums="actionlint_${version}_checksums.txt"
    temporary_dir="$(mktemp -d)"
    log "install actionlint $version with SHA-256 verification"
    curl -fsSL \
        "https://github.com/rhysd/actionlint/releases/download/${tag}/${asset}" \
        -o "$temporary_dir/$asset"
    curl -fsSL \
        "https://github.com/rhysd/actionlint/releases/download/${tag}/${checksums}" \
        -o "$temporary_dir/$checksums"
    if ! (
        cd "$temporary_dir"
        grep " ${asset}\$" "$checksums" | sha256sum -c -
    ); then
        rm -rf "$temporary_dir"
        warn "actionlint SHA-256 verification FAILED; refusing to install"
        return 1
    fi
    tar -xzf "$temporary_dir/$asset" -C "$temporary_dir"
    install -m 0755 "$temporary_dir/actionlint" "$HOME/.local/bin/actionlint"
    rm -rf "$temporary_dir"
    hash -r
}

ensure_osv_scanner_linux() {
    local tag architecture asset temporary_dir
    if have osv-scanner; then
        return 0
    fi
    have curl && have jq && have sha256sum || return 1
    case "$(uname -m)" in
        x86_64) architecture="amd64" ;;
        aarch64|arm64) architecture="arm64" ;;
        *)
            warn "No OSV-Scanner binary mapping for $(uname -m)"
            return 1
            ;;
    esac
    tag="$(github_latest_tag google/osv-scanner)"
    asset="osv-scanner_linux_${architecture}"
    temporary_dir="$(mktemp -d)"
    log "install OSV-Scanner ${tag#v} with SHA-256 verification"
    curl -fsSL \
        "https://github.com/google/osv-scanner/releases/download/${tag}/${asset}" \
        -o "$temporary_dir/$asset"
    curl -fsSL \
        "https://github.com/google/osv-scanner/releases/download/${tag}/osv-scanner_SHA256SUMS" \
        -o "$temporary_dir/osv-scanner_SHA256SUMS"
    if ! (
        cd "$temporary_dir"
        grep "  ${asset}\$" osv-scanner_SHA256SUMS | sha256sum -c -
    ); then
        rm -rf "$temporary_dir"
        warn "OSV-Scanner SHA-256 verification FAILED; refusing to install"
        return 1
    fi
    install -m 0755 "$temporary_dir/$asset" "$HOME/.local/bin/osv-scanner"
    rm -rf "$temporary_dir"
    hash -r
}

ensure_linux_tools() {
    if have apt-get && [[ "${ALPHAHENG_BASELINE_APT_UPDATE:-0}" == "1" ]]; then
        log "apt-get update"
        sudo_cmd env DEBIAN_FRONTEND=noninteractive apt-get update -o Acquire::Retries=3
    fi

    apt_install_if_missing curl curl || true
    apt_install_if_missing jq jq || true
    apt_install_if_missing python3 python3 || true
    apt_install_if_missing xz xz-utils || true
    apt_install_if_missing minisign minisign || true
    apt_install_if_missing ccache ccache || true
    apt_install_if_missing sccache sccache || cargo_install_if_missing sccache sccache || true
    apt_install_if_missing cmake cmake || true
    apt_install_if_missing ninja ninja-build || true
    apt_install_if_missing just just || cargo_install_if_missing just just || true
    apt_install_if_missing rg ripgrep || cargo_install_if_missing rg ripgrep || true
    apt_install_if_missing fdfind fd-find || cargo_install_if_missing fd fd-find || true
    apt_install_if_missing batcat bat || cargo_install_if_missing bat bat || true
    apt_install_if_missing delta git-delta || cargo_install_if_missing delta git-delta || true
    apt_install_if_missing hyperfine hyperfine || cargo_install_if_missing hyperfine hyperfine || true
    apt_install_if_missing shellcheck shellcheck || true
    apt_install_if_missing shfmt shfmt || true
    apt_install_if_missing gh gh || true
    apt_install_if_missing git-lfs git-lfs || true
    apt_install_if_missing aria2c aria2 || true
    apt_install_if_missing rclone rclone || true
    apt_install_if_missing zstd zstd || true
    apt_install_if_missing mosh mosh || true
    # Fresh Server installations do not have Cargo. These tools are needed to
    # build cargo-audit/cargo-deny and their native dependencies below.
    apt_install_if_missing cargo cargo || true
    apt_install_if_missing cc build-essential || true
    apt_install_if_missing pkg-config pkg-config || true
    if have apt-get; then
        sudo_cmd env DEBIAN_FRONTEND=noninteractive apt-get install -y \
            --no-install-recommends -o Acquire::Retries=3 libssl-dev || true
    fi

    mkdir -p "$HOME/.local/bin"
    if ! have fd && have fdfind; then
        ln -sf "$(command -v fdfind)" "$HOME/.local/bin/fd"
    fi
    if ! have bat && have batcat; then
        ln -sf "$(command -v batcat)" "$HOME/.local/bin/bat"
    fi
    export PATH="$HOME/.local/bin:$PATH"

    ensure_latest_ccache_linux || true
    ensure_latest_sccache_linux || true
    ensure_yq_linux || true
    ensure_actionlint_linux || true
    ensure_osv_scanner_linux || true
}

install_missing() {
    if [[ "$(uname -s)" == "Darwin" ]]; then
        ensure_homebrew_tools || true
    else
        # Install apt prerequisites (incl. curl) first so the curl-backed
        # pixi/hf installers below succeed on a minimal host in a single run.
        ensure_linux_tools || true
    fi
    ensure_uv || true
    ensure_pixi || true
    ensure_hf || true
    ensure_hfd_cli || warn "hfd installation failed; final baseline check will fail"
    cargo_install_if_missing cargo-audit cargo-audit || \
        warn "cargo-audit installation failed; final baseline check will fail"
    cargo_install_if_missing cargo-deny cargo-deny || \
        warn "cargo-deny installation failed; final baseline check will fail"
    ensure_uv_tool ruff || true
    ensure_uv_tool ty || true
    ensure_uv_tool zizmor || true
    ensure_pip_audit || \
        warn "pip-audit installation failed; final baseline check will fail"
}

# Report (without installing) whether installed ccache/sccache are at least the
# latest upstream release. Used by --check so the current-release requirement is
# verified, not just binary presence. Returns nonzero when a tool is stale.
check_cache_tool_currency() {
    local tool current tag version
    for tool in ccache sccache; do
        have "$tool" || continue
        if ! have curl || ! have jq; then
            continue
        fi
        case "$tool" in
            ccache) tag="$(github_latest_tag ccache/ccache 2>/dev/null || true)"
                    current="$("$tool" --version 2>/dev/null | awk 'NR == 1 {print $3}')" ;;
            sccache) tag="$(github_latest_tag mozilla/sccache 2>/dev/null || true)"
                     current="$("$tool" --version 2>/dev/null | awk 'NR == 1 {print $2}')" ;;
        esac
        version="${tag#v}"
        if [[ -n "$version" ]] && ! version_at_least "$current" "$version"; then
            warn "$tool $current is older than the latest upstream release $version"
            return 1
        fi
    done
    return 0
}

show_versions() {
    local failed=0
    local tool path version
    for tool in "${REQUIRED_TOOLS[@]}"; do
        if ! tool_available "$tool" || ! path="$(command -v "$tool" 2>/dev/null)"; then
            printf '%-12s MISSING\n' "$tool"
            failed=1
            continue
        fi
        version="$("$tool" --version 2>/dev/null | head -1 || true)"
        printf '%-12s %s%s\n' "$tool" "$path" "${version:+  ($version)}"
    done
    return "$failed"
}

main() {
    local status=0
    if [[ "$MODE" == "install" ]]; then
        install_missing
    elif [[ "$(uname -s)" != "Darwin" ]]; then
        # --check on Linux: the current-release requirement is enforced where
        # the version-pinned installers run, so verify currency without installing.
        check_cache_tool_currency || status=1
    fi

    show_versions || status=1
    return "$status"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main
fi
