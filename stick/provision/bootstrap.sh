#!/usr/bin/env bash
# Ventoy provision bootstrap: Codex + CCR-Rust router + GLM-5.3 on fresh Ubuntu 26.04.
# Profile-based: pick a bundle under provision/profiles/<name>/ (default: "default").
#
# Flows:
#   sudo bash <stick>/provision/bootstrap.sh [--profile NAME]     # full, after desktop/manual install
#   sudo bash .../bootstrap.sh --finish-secrets [--profile NAME]  # secrets only (retry if skipped)
#   sudo bash .../bootstrap.sh --reset-password [--profile NAME]  # set target user password
#   bash .../bootstrap.sh --healthcheck [--profile NAME]          # read-only health probe
#   bash /root/provision-copy/bootstrap.sh --chrooted --profile NAME   # autoinstall late-command
#
# Idempotent: safe to re-run. Logs to /var/log/ventoy-bootstrap.log (except --healthcheck).
set -Eeuo pipefail
umask 077

MODE=full
DO_BASELINE=1
DO_SMOKE=1
PROFILE=default
STAGE=start
BASELINE_STATUS=skipped
SECRETS_STATUS=skipped
SERVICES_STATUS=skipped
HEALTH_STATUS=skipped
SMOKE_STATUS=skipped
# stand-up layer (BRINGUP.md field data 2026-09-29); all default off/neutral
# here, real values come from profile.conf
SUDO_STATUS=skipped
CACHE_STATUS=skipped
POLICY_STATUS=skipped
CLAUDE_STATUS=skipped
CLAUDE_SMOKE_STATUS=skipped
NVIDIA_STATUS=skipped
CUDA_STATUS=skipped
ZT_STATUS=skipped
while [ $# -gt 0 ]; do
    case "$1" in
        --chrooted) MODE=chrooted ;;
        --finish-secrets) MODE=finish-secrets ;;
        --reset-password) MODE=reset-password ;;
        --healthcheck) MODE=healthcheck ;;
        --no-baseline) DO_BASELINE=0 ;;
        --no-smoke) DO_SMOKE=0 ;;
        --profile) shift; PROFILE="${1:?--profile needs a name}" ;;
        *) echo "unknown arg: $1" >&2; exit 2 ;;
    esac
    shift
done
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
LOG=/var/log/ventoy-bootstrap.log

PROFILE_DIR="$SCRIPT_DIR/profiles/$PROFILE"
early_fatal() { # stage rc — evidence for failures that precede the log/trap setup
    echo "rc=$2 stage=$1 profile=$PROFILE dir=$PROFILE_DIR date=$(date -Is 2>/dev/null || date)" \
        > /root/BOOTSTRAP-FAILED 2>/dev/null || true
}
if [ ! -f "$PROFILE_DIR/profile.conf" ]; then
    early_fatal profile.conf-missing 2
    echo "profile '$PROFILE' not found under $SCRIPT_DIR/profiles/" >&2
    ls "$SCRIPT_DIR/profiles/" >&2 2>/dev/null || echo "(no profiles dir)" >&2
    exit 2
fi
# profile.conf: TARGET_USER, REALNAME, GIT_EMAIL, ENABLE_CCR_MAIN, ENABLE_GLM_WORKERS,
#   ENABLE_ZCODE_CREDS, plus stand-up flags (all optional, defaults in make-profile.sh):
#   ENABLE_PASSWORDLESS_SUDO, ENABLE_BUILD_CACHE, ENABLE_POLICY_FILES, ENABLE_CLAUDE,
#   CLAUDE_MODEL_TIER, ENABLE_NVIDIA, NVIDIA_DRIVER_PKG, ENABLE_CUDA, ENABLE_ZEROTIER,
#   ZT_NETWORK_ID
# Neutral fallback for a broken profile.conf; every real profile overrides these.
TARGET_USER=provision REALNAME="Provisioned User" GIT_EMAIL="provision@example.invalid" \
ENABLE_CCR_MAIN=1 ENABLE_GLM_WORKERS=1 ENABLE_ZCODE_CREDS=1
: "${CLAUDE_MODEL_TIER:=zai,glm-5.3[1m]}"
source "$PROFILE_DIR/profile.conf" \
    || { early_fatal profile.conf-source $?; echo "cannot source $PROFILE_DIR/profile.conf" >&2; exit 2; }
TARGET_HOME="/home/$TARGET_USER"

log() { printf '[%s] %s\n' "$(date -Is)" "$*"; }

stage() {
    STAGE=$1
    log "--- stage: $STAGE ---"
}

as_user() {
    local uid
    uid=$(id -u "$TARGET_USER")
    runuser -u "$TARGET_USER" -- env HOME="$TARGET_HOME" USER="$TARGET_USER" \
        XDG_RUNTIME_DIR="/run/user/$uid" DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$uid/bus" "$@"
}

healthcheck() {
    # 0 iff the GLM listener answers with the flashx model (GLM profiles only)
    [ "$ENABLE_GLM_WORKERS" = 1 ] || return 1
    local bearer models
    bearer=$(sed -n 's/^experimental_bearer_token *= *"\(.*\)".*/\1/p' "$TARGET_HOME/.codex/ccr.config.toml" 2>/dev/null | head -1)
    if [ -z "$bearer" ]; then
        return 1
    fi
    models=$(curl -sS -m 8 -H "Authorization: Bearer $bearer" http://127.0.0.1:3457/v1/models 2>/dev/null || true)
    printf '%s' "$models" | grep -q 'glm-5.3-flashx'
}

if [ "$MODE" = healthcheck ]; then
    if [ "$ENABLE_GLM_WORKERS" != 1 ]; then echo "GLM workers disabled by profile '$PROFILE'"; exit 0; fi
    if healthcheck; then echo "CCR GLM listener: OK (glm-5.3-flashx advertised)"; exit 0
    else echo "CCR GLM listener: DOWN or not provisioned"; exit 1; fi
fi

[ "$(id -u)" -eq 0 ] || { echo "run with sudo (root required)" >&2; exit 1; }

# ---------------------------------------------------------------- password reset (needs a real tty, before log redirection)
if [ "$MODE" = reset-password ]; then
    mkdir -p "$(dirname "$LOG")"
    read -r -s -p "New password for $TARGET_USER: " PW1 </dev/tty; echo "" >/dev/tty
    read -r -s -p "Confirm: " PW2 </dev/tty; echo "" >/dev/tty
    [ "$PW1" = "$PW2" ] || { echo "passwords differ" >&2; exit 1; }
    printf '%s:%s\n' "$TARGET_USER" "$PW1" | chpasswd
    echo "password updated for $TARGET_USER"
    exit 0
fi

mkdir -p "$(dirname "$LOG")" 2>/dev/null || true
if ! : >>"$LOG" 2>/dev/null; then
    # cannot open the log (read-only /var, ENOSPC, path is a dir): fall back to
    # the console so a set -e death here still leaves a visible trace
    LOG=/dev/console
fi
exec >>"$LOG" 2>&1
log "=== bootstrap start: mode=$MODE profile=$PROFILE user=$TARGET_USER script_dir=$SCRIPT_DIR ==="
log "profile flags: CCR_MAIN=$ENABLE_CCR_MAIN GLM_WORKERS=$ENABLE_GLM_WORKERS ZCODE_CREDS=$ENABLE_ZCODE_CREDS"
if [ "$MODE" = chrooted ] || [ "$MODE" = full ] || [ "$MODE" = finish-secrets ]; then
    mkdir -p /root 2>/dev/null || true
    rm -f /root/BOOTSTRAP-OK /root/BOOTSTRAP-STAGED /root/BOOTSTRAP-FAILED
fi

# a set -e death anywhere after this point leaves machine-readable evidence
fatal() { # rc line
    local rc=$1 line=$2
    log "FATAL: rc=$rc at line $line stage=$STAGE (mode=$MODE profile=$PROFILE)"
    printf 'rc=%s line=%s stage=%s mode=%s profile=%s date=%s\n' \
        "$rc" "$line" "$STAGE" "$MODE" "$PROFILE" "$(date -Is)" \
        > /root/BOOTSTRAP-FAILED 2>/dev/null || true
    printf '%s\n' "$rc" > /root/BOOTSTRAP-RC 2>/dev/null || true
}
trap 'rc=$?; fatal "$rc" "$LINENO"; exit "$rc"' ERR

# ---------------------------------------------------------------- helpers
install_file() { # src dst mode
    install -D -m "$3" "$1" "$2" || return $?
    chown "$TARGET_USER:$TARGET_USER" "$2" 2>/dev/null || true
}

extract_secrets() {
    # plain bundle (owner decision: internal tool) -> /tmp/provision-secrets
    local bundle="$PROFILE_DIR/secrets.tar"
    [ -f "$bundle" ] || { log "WARN: $bundle not found; skipping secrets"; return 1; }
    rm -rf /tmp/provision-secrets && mkdir -p /tmp/provision-secrets
    if ! tar -xf "$bundle" -C /tmp/provision-secrets; then
        log "WARN: secrets bundle extract failed"
        rm -rf /tmp/provision-secrets
        return 1
    fi
    return 0
}

install_secrets() {
    local s=/tmp/provision-secrets
    [ -d "$s" ] || { extract_secrets || return 1; }
    local failed=0 required
    local required_files=(codex/auth.json codex/config.toml)
    if [ "$ENABLE_CCR_MAIN" = 1 ] || [ "$ENABLE_GLM_WORKERS" = 1 ]; then
        required_files+=(ccr/runtime-credentials.json)
    fi
    if [ "$ENABLE_ZCODE_CREDS" = 1 ]; then
        required_files+=(zcode/credentials.json zcode/provider_config.json)
    fi
    for required in "${required_files[@]}"; do
        if [ ! -s "$s/$required" ]; then
            log "ERROR: secrets bundle missing required file: $required"
            return 1
        fi
    done
    if [ -f "$s/codex/auth.json" ]; then
        install_file "$s/codex/auth.json" "$TARGET_HOME/.codex/auth.json" 600 || failed=1
    fi
    if [ -f "$s/codex/config.toml" ]; then
        sed "s|__HOME__|$TARGET_HOME|g" "$s/codex/config.toml" > /tmp/codex-config.toml
        install_file /tmp/codex-config.toml "$TARGET_HOME/.codex/ccr.config.toml" 600 || failed=1
        install_file /tmp/codex-config.toml "$TARGET_HOME/.codex/config.toml" 600 || failed=1
        rm -f /tmp/codex-config.toml
    fi
    if [ -f "$s/ccr/runtime-credentials.json" ]; then
        install_file "$s/ccr/runtime-credentials.json" \
            "$TARGET_HOME/.claude-code-router/runtime-credentials.json" 600 || failed=1
    fi
    if [ "$ENABLE_ZCODE_CREDS" = 1 ]; then
        if [ -f "$s/zcode/credentials.json" ]; then
            install_file "$s/zcode/credentials.json" "$TARGET_HOME/.zcode/v2/credentials.json" 600 || failed=1
        fi
        if [ -f "$s/zcode/provider_config.json" ]; then
            install_file "$s/zcode/provider_config.json" \
                "$TARGET_HOME/.zcode/v2/provider_config.json" 600 || failed=1
        fi
    fi
    rm -rf /tmp/provision-secrets
    if [ "$failed" -ne 0 ]; then
        log "ERROR: one or more secret files failed to install"
        return 1
    fi
    log "secrets installed (profile=$PROFILE)"
}

# Remove likely credential material before placing any command output in the log.
redact_sensitive() {
    sed -E \
        -e 's/(experimental_bearer_token[[:space:]]*=[[:space:]]*)"[^"]+"/\1"[REDACTED]"/g' \
        -e 's/(Authorization[: ]*Bearer )[A-Za-z0-9._~+/=-]{8,}/\1[REDACTED]/Ig' \
        -e 's/("(api[_-]?key|token|access[_-]?token|refresh[_-]?token)"[[:space:]]*:[[:space:]]*)"[^"]+"/\1"[REDACTED]"/Ig'
}

# ---------------------------------------------------------------- install binaries, configs, units (not in finish-secrets)
if [ "$MODE" != finish-secrets ]; then
    stage install-files
    log "installing binaries"
    mkdir -p "$TARGET_HOME/.local/bin" "$TARGET_HOME/.cargo/bin"
    install -D -m 755 "$SCRIPT_DIR/bin/codex" "$TARGET_HOME/.local/bin/codex"
    install -D -m 755 "$SCRIPT_DIR/bin/codex-code-mode-host" "$TARGET_HOME/.local/bin/codex-code-mode-host"
    install -D -m 755 "$SCRIPT_DIR/bin/ccr-rust" "$TARGET_HOME/.cargo/bin/ccr-rust"
    chown -R "$TARGET_USER:$TARGET_USER" "$TARGET_HOME/.local" "$TARGET_HOME/.cargo" 2>/dev/null || true

    log "installing CCR configs (env placeholders; real keys arrive via secrets)"
    mkdir -p "$TARGET_HOME/.claude-code-router"
    install_file "$SCRIPT_DIR/files/ccr/config.json" "$TARGET_HOME/.claude-code-router/config.json" 600
    install_file "$SCRIPT_DIR/files/ccr/glm-workers.json" "$TARGET_HOME/.claude-code-router/glm-workers.json" 600
    install_file "$SCRIPT_DIR/files/ccr-model-catalog.json" "$TARGET_HOME/.codex/ccr-live-model-catalog.json" 644

    log "installing ccr-serve launcher + systemd user units"
    install -D -m 755 "$SCRIPT_DIR/ccr-serve.py" "$TARGET_HOME/.local/bin/ccr-serve"
    UDIR="$TARGET_HOME/.config/systemd/user"
    mkdir -p "$UDIR/default.target.wants"
    cat > "$UDIR/ccr-main.service" <<'EOF'
[Unit]
Description=CCR-Rust main listener (127.0.0.1:3456)
After=network-online.target

[Service]
ExecStart=%h/.local/bin/ccr-serve main
Restart=on-failure
RestartSec=3

[Install]
WantedBy=default.target
EOF
    cat > "$UDIR/ccr-glm-workers.service" <<'EOF'
[Unit]
Description=CCR-Rust GLM workers listener (127.0.0.1:3457)
After=network-online.target

[Service]
ExecStart=%h/.local/bin/ccr-serve workers
Restart=on-failure
RestartSec=3

[Install]
WantedBy=default.target
EOF
    if [ "$ENABLE_CCR_MAIN" = 1 ]; then ln -sfn "$UDIR/ccr-main.service" "$UDIR/default.target.wants/ccr-main.service"; fi
    if [ "$ENABLE_GLM_WORKERS" = 1 ]; then ln -sfn "$UDIR/ccr-glm-workers.service" "$UDIR/default.target.wants/ccr-glm-workers.service"; fi
    chown -R "$TARGET_USER:$TARGET_USER" "$TARGET_HOME/.config" 2>/dev/null || true

    if [ "$ENABLE_GLM_WORKERS" = 1 ]; then
        log "compat shims (ccr-glm-workers-local, codex-ccr, ccr-healthcheck)"
        cat > "$TARGET_HOME/.local/bin/ccr-glm-workers-local" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-status}" in
    start)   systemctl --user start ccr-glm-workers ;;
    stop)    systemctl --user stop ccr-glm-workers ;;
    restart) systemctl --user restart ccr-glm-workers ;;
    status)  systemctl --user is-active ccr-glm-workers ;;
    *) echo "usage: $0 {start|stop|restart|status}" >&2; exit 2 ;;
esac
EOF
        cat > "$TARGET_HOME/.local/bin/codex-ccr" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
curl --fail --silent --max-time 2 http://127.0.0.1:3457/health >/dev/null 2>&1 \
    || systemctl --user start ccr-glm-workers >/dev/null 2>&1 || true
exec "$HOME/.local/bin/codex" --profile ccr "$@"
EOF
        cat > "$TARGET_HOME/.local/bin/ccr-healthcheck" <<'EOF'
#!/usr/bin/env bash
# exits 0 when the GLM listener advertises glm-5.3-flashx
bearer=$(sed -n 's/^experimental_bearer_token *= *"\(.*\)".*/\1/p' "$HOME/.codex/ccr.config.toml" 2>/dev/null | head -1)
[ -n "$bearer" ] || { echo "secrets not finished"; exit 1; }
curl -sS -m 8 -H "Authorization: Bearer $bearer" http://127.0.0.1:3457/v1/models 2>/dev/null | grep -q glm-5.3-flashx
EOF
        chmod 755 "$TARGET_HOME/.local/bin/ccr-glm-workers-local" "$TARGET_HOME/.local/bin/codex-ccr" "$TARGET_HOME/.local/bin/ccr-healthcheck"
    fi

    log "SSH authorized_keys from profile keys"
    mkdir -p "$TARGET_HOME/.ssh"; chmod 700 "$TARGET_HOME/.ssh"
    touch "$TARGET_HOME/.ssh/authorized_keys"; chmod 600 "$TARGET_HOME/.ssh/authorized_keys"
    for pub in "$PROFILE_DIR"/ssh/*.pub; do
        [ -f "$pub" ] || continue
        key=$(cat "$pub")
        grep -qxF "$key" "$TARGET_HOME/.ssh/authorized_keys" || echo "$key" >> "$TARGET_HOME/.ssh/authorized_keys"
    done
    chown -R "$TARGET_USER:$TARGET_USER" "$TARGET_HOME/.ssh" 2>/dev/null || true

    log "git identity: $REALNAME <$GIT_EMAIL>"
    as_user git config --global user.name  "$REALNAME" || true
    as_user git config --global user.email "$GIT_EMAIL" || true
    as_user git config --global init.defaultBranch main || true

    # 2026-09-30 Strix bring-up: if an earlier run installed sccache via
    # baseline but build-cache had not run yet, ~/.cargo/config.toml points at
    # /usr/local/bin/sccache which does not exist, and every cargo install
    # dies with "could not execute process ... (No such file or directory)".
    # Re-create the link before any cargo use; build-cache re-asserts it.
    if [ -x "$TARGET_HOME/.local/bin/sccache" ]; then
        ln -sfn "$TARGET_HOME/.local/bin/sccache" /usr/local/bin/sccache
    fi

    # 2026-09-30 Strix bring-up: two netplan postures the installer leaves out.
    #  (a) subiquity can write netplan with NO dhcp4 (observed when the NIC
    #      gained carrier 5 min into the install), leaving the box IPv6-only --
    #      Ubuntu's archive is v4-only, so every apt stage fails with confusing
    #      downstream errors. Only repaired when there is also no default IPv4
    #      route, so a statically configured box is never handed DHCP.
    #  (b) no wakeonlan key: r8169 comes up with `Wake-on: d` on every boot, so
    #      a remote box cannot be woken from S5. `wakeonlan: true` is what
    #      persists it -- it renders WakeOnLan=magic into the networkd .link
    #      unit; `ethtool -s ... wol g` alone is lost at the next boot.
    if [ "$MODE" != chrooted ] && [ -f /etc/netplan/00-installer-config.yaml ] && \
       grep -q "^network:" /etc/netplan/00-installer-config.yaml; then
        want=""
        if ! ip -4 route show default 2>/dev/null | grep -q . && \
           ! grep -qE "^[[:space:]]*dhcp4:" /etc/netplan/00-installer-config.yaml; then
            want="dhcp4"
        fi
        if ! grep -qE "^[[:space:]]*wakeonlan:" /etc/netplan/00-installer-config.yaml; then
            want="${want:+$want,}wakeonlan"
        fi
        if [ -n "$want" ]; then
            cp -a /etc/netplan/00-installer-config.yaml \
                "/etc/netplan/00-installer-config.yaml.bak-$(date +%Y%m%d-%H%M%S)"
            if NETPLAN_WANT="$want" python3 - <<'PYEOF'
import os
import re

path = "/etc/netplan/00-installer-config.yaml"
want = os.environ.get("NETPLAN_WANT", "").split(",")
lines = open(path).read().splitlines()
out, i, n, added = [], 0, len(lines), []


def indent(s):
    return len(s) - len(s.lstrip(" "))


while i < n:
    line = lines[i]
    m = re.match(r"^(\s*)ethernets:\s*$", line)
    if m and indent(line) == 2:
        base, iface = indent(line), indent(line) + 2
        out.append(line)
        i += 1
        while i < n:
            l2 = lines[i]
            if l2.strip() and indent(l2) <= base:
                break
            if l2.strip() and indent(l2) == iface and not l2.lstrip().startswith("#"):
                name = l2.strip().rstrip(":")
                out.append(l2)
                i += 1
                stanza = []
                while i < n and (not lines[i].strip() or indent(lines[i]) > iface):
                    stanza.append(lines[i])
                    i += 1
                add = []
                if "dhcp4" in want and not any(re.match(r"^\s*dhcp4:", s) for s in stanza):
                    add.append("dhcp4: true")
                if "wakeonlan" in want and not any(re.match(r"^\s*wakeonlan:", s) for s in stanza):
                    add.append("wakeonlan: true")
                trail = 0
                while trail < len(stanza) and not stanza[len(stanza) - 1 - trail].strip():
                    trail += 1
                body = len(stanza) - trail
                out.extend(stanza[:body])
                for a in add:
                    out.append(" " * (iface + 2) + a)
                    added.append("%s: %s" % (name, a))
                out.extend(stanza[body:])
                continue
            out.append(l2)
            i += 1
        continue
    out.append(line)
    i += 1
open(path, "w").write("\n".join(out) + "\n")
print("; ".join(added) if added else "no stanzas needed changes")
PYEOF
            then
                if netplan generate >/dev/null 2>&1; then
                    netplan apply
                    log "netplan posture guard applied ($want; backup beside the original)"
                    case "$want" in
                    *dhcp4*)
                        for _ in $(seq 1 15); do
                            ip -4 route show default 2>/dev/null | grep -q . && break
                            sleep 2
                        done
                        if ip -4 route show default 2>/dev/null | grep -q .; then
                            log "ACCEPTANCE: default IPv4 route present after netplan fix"
                        else
                            log "WARN: still no default IPv4 route after netplan fix (v6-only network?)"
                        fi
                        ;;
                    esac
                else
                    log "ERROR: netplan posture guard produced an invalid config; NOT applied"
                fi
            else
                log "ERROR: netplan posture guard edit failed; NOT applied"
            fi
        fi
    fi

    if [ "$MODE" != chrooted ] && [ "$DO_BASELINE" = 1 ] && [ -f "$SCRIPT_DIR/files/install-baseline-tools.sh" ]; then
        stage baseline
        log "AlphaHENG baseline tools (30 minute limit, HOME=$TARGET_HOME)"
        # HOME override so uv/pixi/hf land in the target user's home, not /root;
        # ownership is normalized in the final chown pass
        HOME="$TARGET_HOME" USER="$TARGET_USER" ALPHAHENG_BASELINE_APT_UPDATE=1 \
            timeout --kill-after=30 1800 bash "$SCRIPT_DIR/files/install-baseline-tools.sh" \
            || BASELINE_STATUS=failed
        if [ "$BASELINE_STATUS" != failed ]; then BASELINE_STATUS=ok; fi
        if [ "$BASELINE_STATUS" != ok ]; then
            log "ERROR: baseline install failed; full completion will not be marked"
        fi
    elif [ "$MODE" = full ] && [ "$DO_BASELINE" = 1 ]; then
        BASELINE_STATUS=missing
        log "ERROR: baseline installer missing; full completion will not be marked"
    fi

    # ---------------------------------------------------------------- stand-up layer
    # Everything BRINGUP.md had to do by hand on 2026-09-29, now provisioned.
    # full mode only: chrooted runs in the installer env with no network, and
    # finish-secrets must never touch anything but secrets.
    if [ "$MODE" = full ]; then

        if [ "${ENABLE_PASSWORDLESS_SUDO:-0}" = 1 ]; then
            stage sudo
            SUDO_STATUS=failed
            printf '%s ALL=(ALL) NOPASSWD: ALL\n' "$TARGET_USER" > /tmp/sudoers.$$
            if visudo -cf /tmp/sudoers.$$ >/dev/null 2>&1; then
                install -D -m 0440 /tmp/sudoers.$$ "/etc/sudoers.d/$TARGET_USER"
                SUDO_STATUS=ok
                log "ACCEPTANCE: passwordless sudo for $TARGET_USER (visudo-validated)"
            else
                log "ERROR: sudoers fragment failed visudo -c; NOT installed"
            fi
            rm -f /tmp/sudoers.$$
        fi

        if [ "${ENABLE_BUILD_CACHE:-1}" = 1 ]; then
            stage build-cache
            CACHE_STATUS=failed
            # Ubuntu 26.04 pam_env does NOT inject /etc/environment into ssh
            # sessions (field-verified 2026-09-29): cargo config + profile.d are
            # the two live paths; /etc/environment entries would be inert.
            cat > /etc/profile.d/00-build-cache.sh <<'PROFILEEOF'
export RUSTC_WRAPPER=/usr/local/bin/sccache
export CARGO_INCREMENTAL=0
export SCCACHE_CACHE_SIZE=50G
PROFILEEOF
            chmod 644 /etc/profile.d/00-build-cache.sh || true
            mkdir -p "$TARGET_HOME/.cargo" "$TARGET_HOME/.config/ccache"
            # absolute wrapper path so PATH order never decides which sccache runs
            cat > "$TARGET_HOME/.cargo/config.toml" <<'CARGOEOF'
[build]
rustc-wrapper = "/usr/local/bin/sccache"
incremental = false

[env]
SCCACHE_CACHE_SIZE = "50G"
CARGOEOF
            cat > "$TARGET_HOME/.config/ccache/ccache.conf" <<'CCACHEEOF'
max_size = 50G
inode_cache = true
CCACHEEOF
            chown -R "$TARGET_USER:$TARGET_USER" "$TARGET_HOME/.cargo" "$TARGET_HOME/.config" 2>/dev/null || true
            # canonical sccache = the baseline's static build; apt's is a shadowed
            # fallback. Symlink only when the binary exists (baseline may have
            # failed); config files alone still mark the stage ok.
            if [ -x "$TARGET_HOME/.local/bin/sccache" ]; then
                ln -sfn "$TARGET_HOME/.local/bin/sccache" /usr/local/bin/sccache
            else
                log "WARN: sccache binary absent (baseline incomplete?); /usr/local/bin/sccache symlink deferred"
            fi
            [ -s /etc/profile.d/00-build-cache.sh ] && [ -s "$TARGET_HOME/.cargo/config.toml" ] && CACHE_STATUS=ok
        fi

        if [ "${ENABLE_POLICY_FILES:-1}" = 1 ] && [ -f "$SCRIPT_DIR/files/AGENTS-core.md" ]; then
            stage policy
            POLICY_STATUS=failed
            mkdir -p "$TARGET_HOME/.claude"
            if install_file "$SCRIPT_DIR/files/AGENTS-core.md" "$TARGET_HOME/AGENTS.md" 644 && \
               install_file "$SCRIPT_DIR/files/AGENTS-core.md" "$TARGET_HOME/.codex/AGENTS.md" 644 && \
               printf '# Global Instructions\n\n@~/AGENTS.md\n' > "$TARGET_HOME/.claude/CLAUDE.md"; then
                chown "$TARGET_USER:$TARGET_USER" "$TARGET_HOME/.claude/CLAUDE.md" 2>/dev/null || true
                POLICY_STATUS=ok
                log "policy files installed (~/AGENTS.md, ~/.codex/AGENTS.md, ~/.claude/CLAUDE.md stub)"
            else
                log "ERROR: policy file installation failed"
            fi
        fi

        if [ "${ENABLE_CLAUDE:-0}" = 1 ] && [ "$ENABLE_CCR_MAIN" = 1 ]; then
            stage claude-code
            CLAUDE_STATUS=failed
            if [ ! -x "$TARGET_HOME/.local/bin/claude" ]; then
                log "installing Claude Code (native installer)"
                as_user bash -c 'curl -fsSL --retry 3 --connect-timeout 15 --max-time 300 https://claude.ai/install.sh | bash' || true
            fi
            if [ -x "$TARGET_HOME/.local/bin/claude" ]; then
                cat > "$TARGET_HOME/.local/bin/claude-ccr" <<LAUNCHEREOF
#!/usr/bin/env bash
set -euo pipefail
curl --fail --silent --max-time 2 http://127.0.0.1:3456/health >/dev/null 2>&1 \\
    || systemctl --user start ccr-main.service >&2
export ANTHROPIC_BASE_URL="http://127.0.0.1:3456"
export ANTHROPIC_AUTH_TOKEN="ccr-local"
export ANTHROPIC_API_KEY="ccr-local"
export ANTHROPIC_MODEL="$CLAUDE_MODEL_TIER"
export ANTHROPIC_DEFAULT_FABLE_MODEL="$CLAUDE_MODEL_TIER"
export CLAUDE_CODE_SUBAGENT_MODEL="$CLAUDE_MODEL_TIER"
export CLAUDE_CODE_NO_MODEL_FALLBACK=1
export ANTHROPIC_DEFAULT_OPUS_MODEL="$CLAUDE_MODEL_TIER"
export ANTHROPIC_DEFAULT_SONNET_MODEL="$CLAUDE_MODEL_TIER"
export ANTHROPIC_DEFAULT_HAIKU_MODEL="$CLAUDE_MODEL_TIER"
exec "\$HOME/.local/bin/claude" "\$@"
LAUNCHEREOF
                chmod 755 "$TARGET_HOME/.local/bin/claude-ccr"
                mkdir -p "$TARGET_HOME/.claude"
                cat > "$TARGET_HOME/.claude/settings.json" <<SETTINGSEOF
{
  "env": {
    "API_TIMEOUT_MS": "3000000",
    "ANTHROPIC_BASE_URL": "http://127.0.0.1:3456",
    "ANTHROPIC_API_BASE_URL": "http://127.0.0.1:3456",
    "CLAUDE_AGENT_API_BASE_URL": "http://127.0.0.1:3456",
    "ANTHROPIC_AUTH_TOKEN": "ccr-local",
    "ANTHROPIC_API_KEY": "ccr-local",
    "NO_PROXY": "127.0.0.1,localhost,::1",
    "no_proxy": "127.0.0.1,localhost,::1",
    "CLAUDE_CODE_MAX_OUTPUT_TOKENS": "128000",
    "CLAUDE_CODE_NO_MODEL_FALLBACK": "1",
    "ANTHROPIC_DEFAULT_FABLE_MODEL": "$CLAUDE_MODEL_TIER",
    "ANTHROPIC_DEFAULT_OPUS_MODEL": "$CLAUDE_MODEL_TIER",
    "ANTHROPIC_DEFAULT_SONNET_MODEL": "$CLAUDE_MODEL_TIER",
    "ANTHROPIC_DEFAULT_HAIKU_MODEL": "$CLAUDE_MODEL_TIER",
    "CLAUDE_CODE_SUBAGENT_MODEL": "$CLAUDE_MODEL_TIER",
    "CLAUDE_CODE_MAX_CONTEXT_TOKENS": "1000000"
  }
}
SETTINGSEOF
                chown -R "$TARGET_USER:$TARGET_USER" "$TARGET_HOME/.claude" "$TARGET_HOME/.local/bin/claude-ccr" 2>/dev/null || true
                CLAUDE_STATUS=ok
                log "claude-ccr launcher + settings installed (tier=$CLAUDE_MODEL_TIER)"
            else
                log "ERROR: claude binary not present after install attempt"
            fi
        fi

        if [ "${ENABLE_NVIDIA:-0}" = 1 ]; then
            stage nvidia
            NVIDIA_STATUS=failed
            # the -open kernel modules are unsigned: Secure Boot must be off
            if command -v mokutil >/dev/null 2>&1 && mokutil --sb-state 2>/dev/null | grep -q 'SecureBoot enabled'; then
                log "ERROR: Secure Boot is ON; unsigned open modules will not load. Disable Secure Boot, then re-run bootstrap (retry unit handles it on next boot)."
            else
                if nvidia-smi -L >/dev/null 2>&1; then
                    log "NVIDIA driver already functional; skipping package install"
                    NVIDIA_STATUS=ok
                elif DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
                        -o Acquire::Retries=3 "${NVIDIA_DRIVER_PKG:-nvidia-driver-595-open}"; then
                    log "installed ${NVIDIA_DRIVER_PKG:-nvidia-driver-595-open}"
                else
                    log "ERROR: NVIDIA driver package install failed"
                fi
                if nvidia-smi -L >/dev/null 2>&1; then
                    NVIDIA_STATUS=ok
                    # persistence daemon: the unit is static (no [Install]); enable by hand
                    nvidia-smi -pm 1 >/dev/null 2>&1 || true
                    mkdir -p /etc/systemd/system/multi-user.target.wants
                    ln -sfn /usr/lib/systemd/system/nvidia-persistenced.service \
                        /etc/systemd/system/multi-user.target.wants/nvidia-persistenced.service
                    if nvidia-smi --query-gpu=persistence_mode --format=csv,noheader 2>/dev/null | grep -q '^Enabled'; then
                        log "ACCEPTANCE: GPUs visible with persistence Enabled"
                    fi
                    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
                        -o Acquire::Retries=3 nvtop 2>/dev/null \
                        || log "WARN: nvtop install failed (non-fatal)"
                elif [ "$NVIDIA_STATUS" != ok ]; then
                    log "ERROR: nvidia-smi cannot list GPUs after install (reboot may be needed; retry unit will re-check)"
                fi
            fi
        fi

        if [ "${ENABLE_CUDA:-0}" = 1 ] && [ "$NVIDIA_STATUS" = ok ]; then
            stage cuda
            CUDA_STATUS=failed
            if command -v nvcc >/dev/null 2>&1; then
                CUDA_STATUS=ok
                log "CUDA toolkit already present"
            elif timeout --kill-after=30 1800 env DEBIAN_FRONTEND=noninteractive apt-get install -y \
                    --no-install-recommends -o Acquire::Retries=3 nvidia-cuda-toolkit; then
                nvcc --version >/dev/null 2>&1 && CUDA_STATUS=ok
            else
                log "ERROR: nvidia-cuda-toolkit install failed"
            fi
        fi

        if [ "${ENABLE_ZEROTIER:-0}" = 1 ] && [ -n "${ZT_NETWORK_ID:-}" ]; then
            stage zerotier
            ZT_STATUS=failed
            # 2026-09-30: zerotier-one is NOT in the Ubuntu archive; on a
            # fresh image the bare install below fails with "Unable to locate
            # package zerotier-one". Add the official repo when the package
            # has no candidate version. Keyring is bundled on the stick
            # (files/zerotier-debian-package-key.gpg); "noble" is ZeroTier's
            # newest suite and installs fine on resolute (26.04) -- proven on
            # the B550 and the Strix.
            if ! apt-cache policy zerotier-one 2>/dev/null | grep -qE "Candidate: *[0-9]"; then
                if [ -f "$SCRIPT_DIR/files/zerotier-debian-package-key.gpg" ]; then
                    install -D -m 644 "$SCRIPT_DIR/files/zerotier-debian-package-key.gpg" \
                        /usr/share/keyrings/zerotier-debian-package-key.gpg
                    echo "deb [signed-by=/usr/share/keyrings/zerotier-debian-package-key.gpg] http://download.zerotier.com/debian/noble noble main" \
                        > /etc/apt/sources.list.d/zerotier.list
                    apt-get update -qq >/dev/null 2>&1 || log "WARN: apt update after adding ZeroTier repo failed"
                else
                    log "WARN: zerotier keyring missing from stick payload; trying install without repo"
                fi
            fi
            if command -v zerotier-cli >/dev/null 2>&1 || \
               DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
                   -o Acquire::Retries=3 zerotier-one; then
                systemctl enable --now zerotier-one >/dev/null 2>&1 || true
                for _ in 1 2 3 4 5; do
                    zerotier-cli info >/dev/null 2>&1 && break
                    sleep 2
                done
                if zerotier-cli listnetworks 2>/dev/null | awk '{print $3}' | grep -qx "$ZT_NETWORK_ID"; then
                    ZT_STATUS=ok
                    log "ZeroTier already a member of $ZT_NETWORK_ID"
                elif zerotier-cli join "$ZT_NETWORK_ID" >/dev/null 2>&1; then
                    ZT_STATUS=ok
                    log "ACCEPTANCE: zerotier-cli join $ZT_NETWORK_ID accepted (node sits ACCESS_DENIED until authorized in ZeroTier Central; that step is manual by design)"
                else
                    log "ERROR: zerotier-cli join failed"
                fi
            else
                log "ERROR: zerotier-one install failed"
            fi
        elif [ "${ENABLE_ZEROTIER:-0}" = 1 ]; then
            log "WARN: ENABLE_ZEROTIER=1 but ZT_NETWORK_ID is empty; skipping"
        fi
    fi

    # A single completion unit is installed by latehook. Remove the obsolete
    # checks-only unit, which formerly raced completion and had an ordering cycle.
    rm -f /etc/systemd/system/multi-user.target.wants/provision-firstboot.service \
        /etc/systemd/system/provision-firstboot.service /usr/local/sbin/provision-firstboot.sh
    mkdir -p /var/lib/systemd/linger
    touch "/var/lib/systemd/linger/$TARGET_USER"

fi

# ---------------------------------------------------------------- secrets
stage secrets
if extract_secrets && install_secrets; then
    SECRETS_STATUS=ok
else
    SECRETS_STATUS=failed
    log "ERROR: secrets not installed; later run: bootstrap.sh --finish-secrets --profile $PROFILE"
fi

# ---------------------------------------------------------------- ownership normalization
# In --chrooted mode this script runs as root with no runuser, and install_file
# only chowns files, never the directories mkdir creates under umask 077. Without
# this pass ~/.codex, ~/.claude-code-router and ~/.zcode stay root:root 0700 and
# the target user cannot read their own credentials at first boot.
log "normalizing ownership under $TARGET_HOME"
for d in .local .cargo .config .codex .claude-code-router .zcode .ssh .pixi .cache .claude; do
    if [ -e "$TARGET_HOME/$d" ]; then
        chown -R "$TARGET_USER:$TARGET_USER" "$TARGET_HOME/$d" 2>/dev/null || true
    fi
done
for f in .gitconfig AGENTS.md; do
    if [ -f "$TARGET_HOME/$f" ]; then
        chown "$TARGET_USER:$TARGET_USER" "$TARGET_HOME/$f" 2>/dev/null || true
    fi
done

# ---------------------------------------------------------------- runtime bring-up + acceptance
if [ "$MODE" = full ] || [ "$MODE" = finish-secrets ]; then
    stage runtime
    UNITS=()
    if [ "$ENABLE_CCR_MAIN" = 1 ]; then UNITS+=(ccr-main.service); fi
    if [ "$ENABLE_GLM_WORKERS" = 1 ]; then UNITS+=(ccr-glm-workers.service); fi
    SERVICES_STATUS=ok
    if [ "${#UNITS[@]}" -gt 0 ]; then
        log "starting CCR user services: ${UNITS[*]}"
        uid=$(id -u "$TARGET_USER")
        timeout 30 loginctl enable-linger "$TARGET_USER" || true
        timeout 30 systemctl start "user@$uid.service" || true
        SERVICES_STATUS=failed
        for _ in 1 2 3 4 5; do
            if as_user timeout 20 systemctl --user daemon-reload && \
               as_user timeout 30 systemctl --user enable --now "${UNITS[@]}" && \
               as_user timeout 10 systemctl --user is-active --quiet "${UNITS[@]}"; then
                SERVICES_STATUS=ok
                break
            fi
            sleep 2
        done
        [ "$SERVICES_STATUS" = ok ] || log "ERROR: user service startup failed"
    fi

    HEALTH_STATUS=ok
    SMOKE_STATUS=disabled
    if [ "$ENABLE_GLM_WORKERS" = 1 ]; then
        stage healthcheck
        log "healthcheck (30 second deadline)"
        HEALTH_STATUS=failed
        deadline=$((SECONDS + 30))
        while [ "$SECONDS" -lt "$deadline" ]; do
            if healthcheck; then HEALTH_STATUS=ok; break; fi
            sleep 1
        done
        if [ "$HEALTH_STATUS" = ok ]; then
            log "ACCEPTANCE: ccr 3457 advertises glm-5.3-flashx"
        else
            log "ERROR: GLM listener not healthy; inspect journalctl --user -u ccr-glm-workers"
        fi

        SMOKE_STATUS=skipped
        if [ "$DO_SMOKE" = 1 ]; then
            stage smoke
            SMOKE_STATUS=failed
            if [ "$HEALTH_STATUS" = ok ] && [ "$SECRETS_STATUS" = ok ]; then
                marker="VENTOY-PROVISION-$(date +%s)"
                reply=$(mktemp "$TARGET_HOME/.codex/provision-reply.XXXXXX")
                chown "$TARGET_USER:$TARGET_USER" "$reply"
                log "smoke: codex exec marker=$marker"
                # timeout must wrap an executable, not the as_user shell function.
                # Verify the assistant's final message, never the echoed prompt.
                if out=$(as_user timeout --kill-after=10 180 "$TARGET_HOME/.local/bin/codex" exec \
                    --skip-git-repo-check --output-last-message "$reply" "Reply with exactly: $marker" 2>&1); then
                    if [ "$(cat "$reply")" = "$marker" ]; then
                        SMOKE_STATUS=ok
                        log "ACCEPTANCE: codex final reply matched marker through CCR GLM"
                    else
                        log "ERROR: codex final reply did not match marker"
                    fi
                else
                    log "ERROR: codex exec failed"
                    printf '%s\n' "$out" | tail -20 | redact_sensitive || true
                fi
                rm -f "$reply"
            else
                log "ERROR: smoke skipped because listener or credentials failed"
            fi
        fi
    fi

    # Claude Code smoke rides the MAIN listener (3456), independent of the GLM path
    if [ "$MODE" = full ] && [ "${ENABLE_CLAUDE:-0}" = 1 ] && [ "$CLAUDE_STATUS" = ok ] && [ "$DO_SMOKE" = 1 ]; then
        stage claude-smoke
        CLAUDE_SMOKE_STATUS=failed
        if curl -sf -m 5 http://127.0.0.1:3456/health >/dev/null 2>&1; then
            cmarker="CLAUDE-CCR-$(date +%s)"
            log "smoke: claude-ccr marker=$cmarker"
            if creply=$(as_user timeout --kill-after=10 240 "$TARGET_HOME/.local/bin/claude-ccr" \
                    -p "Reply with exactly: $cmarker" 2>&1); then
                if printf '%s\n' "$creply" | tr -d '\r' | grep -qx "$cmarker"; then
                    CLAUDE_SMOKE_STATUS=ok
                    log "ACCEPTANCE: claude final reply matched marker through ccr-main"
                else
                    log "ERROR: claude final reply did not match marker"
                    printf '%s\n' "$creply" | tail -20 | redact_sensitive || true
                fi
            else
                log "ERROR: claude-ccr -p failed"
                printf '%s\n' "$creply" | tail -20 | redact_sensitive || true
            fi
        else
            log "ERROR: ccr-main health endpoint down; claude smoke skipped as failed"
        fi
    fi
fi

# ---------------------------------------------------------------- completion
log "RESULT: mode=$MODE baseline=$BASELINE_STATUS secrets=$SECRETS_STATUS services=$SERVICES_STATUS health=$HEALTH_STATUS smoke=$SMOKE_STATUS sudo=$SUDO_STATUS caches=$CACHE_STATUS policy=$POLICY_STATUS claude=$CLAUDE_STATUS claude_smoke=$CLAUDE_SMOKE_STATUS nvidia=$NVIDIA_STATUS cuda=$CUDA_STATUS zt=$ZT_STATUS"
for status in "$BASELINE_STATUS" "$SECRETS_STATUS" "$SERVICES_STATUS" "$HEALTH_STATUS" "$SMOKE_STATUS" \
    "$SUDO_STATUS" "$CACHE_STATUS" "$POLICY_STATUS" "$CLAUDE_STATUS" "$CLAUDE_SMOKE_STATUS" \
    "$NVIDIA_STATUS" "$CUDA_STATUS" "$ZT_STATUS"; do
    case "$status" in
        failed|missing)
            fatal 1 "$LINENO"
            printf '1\n' > /root/BOOTSTRAP-RC
            exit 1
            ;;
    esac
done
if [ "$MODE" = full ] && [ "$BASELINE_STATUS" = ok ] && \
    { [ "$ENABLE_GLM_WORKERS" != 1 ] || [ "$SMOKE_STATUS" = ok ]; }; then
    touch /root/BOOTSTRAP-OK
    rm -f /root/BOOTSTRAP-STAGED
    log "=== provisioning complete: all requested checks passed ==="
else
    touch /root/BOOTSTRAP-STAGED
    log "=== provisioning staged: full first-boot completion remains pending ==="
fi
printf '0\n' > /root/BOOTSTRAP-RC
rm -f /root/BOOTSTRAP-FAILED
exit 0
