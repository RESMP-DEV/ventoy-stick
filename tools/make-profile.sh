#!/usr/bin/env bash
# Create or update a provisioning profile in the stick staging tree.
# Portable: ROOT resolves from this script's location.
#
# A profile is a self-contained bundle under stick/provision/profiles/<name>/:
#   profile.conf   identity + capability flags (sourced by bootstrap.sh)
#   ssh/*.pub      authorized_keys for the installed user
#   secrets.tar    codex auth + ccr config + runtime creds + zcode creds (as enabled)
# plus ventoy/autoinstall/<name>.user-data (autoinstall seed for that profile)
# and a regenerated ventoy/ventoy.json (multiple profiles -> boot-time template menu).
#
# Examples:
#   tools/make-profile.sh --name default --user you --realname 'Your Name' \
#       --email you@example.io --hostname compute1 \
#       --password <initial-console-password> --from-mac
#
#   tools/make-profile.sh --name alice --user alice --realname 'Alice Doe' \
#       --email alice@example.io --hostname compute2 --ssh-pub ~/tmp/alice.pub \
#       --from-mac --no-main            # GLM-5.3 worker path only, shared creds
#
#   tools/make-profile.sh --name bob --user bob --realname 'Bob Roe' \
#       --email bob@example.io --ssh-pub bob.pub --secrets-dir ~/tmp/bob-secrets --no-glm --no-zcode
#       # bob-secrets/{codex/auth.json,codex/config.toml,ccr/runtime-credentials.json}
#       # codex/config.toml may use __HOME__ as the home-path placeholder.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
STICK=$ROOT/stick
PROFILES=$STICK/provision/profiles
AUTOINSTALL=$STICK/ventoy/autoinstall

NAME="" USER="" REALNAME="" EMAIL="" HOSTNAME=compute
PASSWORD="" SSH_PUBS=()
SECRETS_DIR="" FROM_MAC=0
GLM=1 MAIN=1 ZCODE=1
# stand-up layer defaults; bootstrap.sh treats absent flags as:
# sudo/nvidia/cuda/claude OFF, cache/policy ON (see its ${VAR:-default} reads)
SUDO=1 POLICY=1 CACHE=1 CLAUDE=1 NVIDIA=0 CUDA=0 ZT=0
ZT_NETWORK_ID=""
NVIDIA_DRIVER_PKG="nvidia-driver-595-open"
CLAUDE_MODEL_TIER="zai,glm-5.3[1m]"
CODEX_CONFIG=""
REFRESH_ONLY=0
while [ $# -gt 0 ]; do
    case "$1" in
        --name) shift; NAME=${1:?} ;;
        --user) shift; USER=${1:?} ;;
        --realname) shift; REALNAME=${1:?} ;;
        --email) shift; EMAIL=${1:?} ;;
        --hostname) shift; HOSTNAME=${1:?} ;;
        --password) shift; PASSWORD=${1:?} ;;
        --ssh-pub) shift; SSH_PUBS+=("${1:?}") ;;
        --secrets-dir) shift; SECRETS_DIR=${1:?} ;;
        --from-mac) FROM_MAC=1 ;;
        --no-glm) GLM=0 ;;
        --no-main) MAIN=0 ;;
        --no-zcode) ZCODE=0 ;;
        --codex-config) shift; CODEX_CONFIG=${1:?} ;;
        --refresh-only) REFRESH_ONLY=1 ;;
        # stand-up layer
        --sudo) SUDO=1 ;;
        --no-sudo) SUDO=0 ;;
        --nvidia) NVIDIA=1 ;;
        --no-nvidia) NVIDIA=0 ;;
        --nvidia-pkg) shift; NVIDIA_DRIVER_PKG=${1:?} ;;
        --cuda) CUDA=1 ;;
        --no-cuda) CUDA=0 ;;
        --zerotier) shift; ZT=1; ZT_NETWORK_ID=${1:?--zerotier needs the network id} ;;
        --no-zerotier) ZT=0 ;;
        --claude) CLAUDE=1 ;;
        --no-claude) CLAUDE=0 ;;
        --claude-tier) shift; CLAUDE_MODEL_TIER=${1:?} ;;
        --no-policy) POLICY=0 ;;
        --no-cache) CACHE=0 ;;
        *) echo "unknown arg: $1" >&2; exit 2 ;;
    esac
    shift
done
[ -n "$NAME" ] || { echo "--name is required" >&2; exit 2; }
[[ "$NAME" =~ ^[a-zA-Z0-9_-]+$ ]] || { echo "invalid profile name" >&2; exit 2; }
PDIR=$PROFILES/$NAME
if [ "$REFRESH_ONLY" = 1 ]; then
    # Refresh generated boot configuration without rotating the stored password,
    # keys, credentials or identity. This is also the repair/deployment path.
    [ -f "$PDIR/profile.conf" ] || { echo "profile not found: $NAME" >&2; exit 2; }
    source "$PDIR/profile.conf"
    USER=$TARGET_USER EMAIL=$GIT_EMAIL PASSWORD=$INITIAL_PASSWORD
    GLM=$ENABLE_GLM_WORKERS MAIN=$ENABLE_CCR_MAIN ZCODE=$ENABLE_ZCODE_CREDS
    SUDO=${ENABLE_PASSWORDLESS_SUDO:-1} POLICY=${ENABLE_POLICY_FILES:-1} CACHE=${ENABLE_BUILD_CACHE:-1}
    CLAUDE=${ENABLE_CLAUDE:-1} NVIDIA=${ENABLE_NVIDIA:-0} CUDA=${ENABLE_CUDA:-0}
    ZT=${ENABLE_ZEROTIER:-0} ZT_NETWORK_ID=${ZT_NETWORK_ID:-}
    NVIDIA_DRIVER_PKG=${NVIDIA_DRIVER_PKG:-nvidia-driver-595-open}
    CLAUDE_MODEL_TIER=${CLAUDE_MODEL_TIER:-zai,glm-5.3[1m]}
fi
for req in NAME USER REALNAME EMAIL; do
    [ -n "${!req}" ] || { echo "--name --user --realname --email are required" >&2; exit 2; }
done
[ "$FROM_MAC" = 1 ] && [ -n "$SECRETS_DIR" ] && { echo "--from-mac and --secrets-dir are exclusive" >&2; exit 2; }
[ "$REFRESH_ONLY" = 0 ] && [ "$FROM_MAC" = 0 ] && [ -z "$SECRETS_DIR" ] && { echo "need --from-mac or --secrets-dir" >&2; exit 2; }
[ -z "$PASSWORD" ] && PASSWORD=$(openssl rand -base64 12)

PDIR=$PROFILES/$NAME
mkdir -p "$PDIR/ssh" "$AUTOINSTALL"

if [ "$REFRESH_ONLY" = 0 ]; then
echo "== profile.conf =="
cat > "$PDIR/profile.conf" <<EOF
# Provisioning profile: $NAME (generated $(date -u +%Y-%m-%dT%H:%M:%SZ) by make-profile.sh)
TARGET_USER="$USER"
REALNAME="$REALNAME"
GIT_EMAIL="$EMAIL"
HOSTNAME="$HOSTNAME"
ENABLE_CCR_MAIN=$MAIN
ENABLE_GLM_WORKERS=$GLM
ENABLE_ZCODE_CREDS=$ZCODE
# stand-up layer (executed by bootstrap.sh in full mode; see BRINGUP.md)
ENABLE_PASSWORDLESS_SUDO=$SUDO
ENABLE_BUILD_CACHE=$CACHE
ENABLE_POLICY_FILES=$POLICY
ENABLE_CLAUDE=$CLAUDE
CLAUDE_MODEL_TIER="$CLAUDE_MODEL_TIER"
ENABLE_NVIDIA=$NVIDIA
NVIDIA_DRIVER_PKG="$NVIDIA_DRIVER_PKG"
ENABLE_CUDA=$CUDA
ENABLE_ZEROTIER=$ZT
ZT_NETWORK_ID="$ZT_NETWORK_ID"
# initial console password (also embedded crypted in ventoy/autoinstall/$NAME.user-data)
INITIAL_PASSWORD="$PASSWORD"
EOF
cat "$PDIR/profile.conf"

echo "== ssh keys =="
for pub in "${SSH_PUBS[@]:-}"; do
    [ -n "$pub" ] || continue
    install -m 644 "$pub" "$PDIR/ssh/$(basename "$pub")"
done
ls -la "$PDIR/ssh/"

echo "== secrets.tar =="
WORK=$(mktemp -d /tmp/ventoy-profile.XXXXXX)
trap 'rm -rf "$WORK"' EXIT
if [ "$FROM_MAC" = 1 ]; then
    # source credentials from THIS machine's codex/CCR/ZCode installs
    mkdir -p "$WORK/codex" "$WORK/ccr" "$WORK/zcode"
    install -m 600 "$HOME/.codex/auth.json" "$WORK/codex/auth.json"
    SRC_CONFIG="${CODEX_CONFIG:-$HOME/.codex/ccr.config.toml}"
    if [ "$GLM" = 1 ]; then
        sed -e "s|$HOME|__HOME__|g" "$SRC_CONFIG" > "$WORK/codex/config.toml"
        cat >> "$WORK/codex/config.toml" <<'EOF'

[profiles.ccr]
model_provider = "ccr_local"
model = "zai,glm-5.3-flashx"
model_reasoning_effort = "max"
EOF
    else
        # no GLM: ship the config with path templating only (user's own provider routing)
        sed -e "s|$HOME|__HOME__|g" "$SRC_CONFIG" > "$WORK/codex/config.toml"
    fi
    chmod 600 "$WORK/codex/config.toml"
    install -m 600 "$HOME/.claude-code-router/runtime-credentials.json" "$WORK/ccr/runtime-credentials.json"
    if [ "$ZCODE" = 1 ]; then
        install -m 600 "$HOME/.zcode/v2/credentials.json" "$WORK/zcode/credentials.json"
        install -m 600 "$HOME/.zcode/v2/provider_config.json" "$WORK/zcode/provider_config.json"
    fi
else
    # caller-provided tree: codex/auth.json, codex/config.toml (__HOME__ templated),
    # ccr/runtime-credentials.json, optional zcode/{credentials,provider_config}.json
    [ -f "$SECRETS_DIR/codex/auth.json" ] || { echo "missing $SECRETS_DIR/codex/auth.json" >&2; exit 1; }
    [ -f "$SECRETS_DIR/codex/config.toml" ] || { echo "missing $SECRETS_DIR/codex/config.toml" >&2; exit 1; }
    [ -f "$SECRETS_DIR/ccr/runtime-credentials.json" ] || { echo "missing $SECRETS_DIR/ccr/runtime-credentials.json" >&2; exit 1; }
    mkdir -p "$WORK"
    cp -R "$SECRETS_DIR/." "$WORK/"
fi
rm -f "$PDIR/secrets.tar"
( cd "$WORK" && find . -type f -print0 | xargs -0 tar -cf "$PDIR/secrets.tar" )
chmod 600 "$PDIR/secrets.tar"
( cd "$WORK" && find . -type f ) | sort
fi

echo "== user-data =="
# Reuse the existing hash when refreshing so identity remains byte-for-byte
# stable while only the generated installation commands change.
CRYPT=""
if [ "$REFRESH_ONLY" = 1 ] && [ -f "$AUTOINSTALL/$NAME.user-data" ]; then
    CRYPT=$(sed -n 's/^    password: "\([^"]*\)"$/\1/p' "$AUTOINSTALL/$NAME.user-data")
fi
[ -n "$CRYPT" ] || CRYPT=$(openssl passwd -6 "$PASSWORD")
SSH_KEYS_YAML=$(python3 - "$PDIR/ssh" <<'PY'
import json, pathlib, sys
# one list element per key line: authorized-keys entries must be single keys
# (a profile .pub file may legitimately contain several)
keys = []
for p in sorted(pathlib.Path(sys.argv[1]).glob('*.pub')):
    keys.extend(line.strip() for line in p.read_text().splitlines() if line.strip())
print('    authorized-keys: ' + json.dumps(keys))
PY
)

# Canonical Ventoy-aware stick mount, shared by early-commands, late-commands
# and error-commands. On a Ventoy boot, ventoy_copy_device_mapper() REPLACES
# the data partition's /dev node (and thus every by-label/by-id symlink) with
# the ISO device-mapper, so the normal by-label mount either fails (rw on an
# ISO) or mounts the ISO. The real partition is still in sysfs: rebuild its
# node, confirm LABEL=Ventoy with blkid, then mount.
VMOUNT_FN=$(cat <<'VMEOF'
vtry_mount() { # $1 = mountpoint; 0 iff the Ventoy data partition with provision/ is mounted (ro ok)
    # Ventoy boots: the read-only ISO dm marks the WHOLE stick disk read-only
    # for the entire live session, so no rw mount of the data partition can
    # succeed ("cannot mount ... read-only") and blkid returns no labels.
    # Mount READ-ONLY instead (provisioning at install time is read-only by
    # design): by-label first, then a vfat/exfat-restricted scan over all
    # block devices including ventoy's dm copies, gated on provision/.
    m=$1
    mkdir -p "$m" 2>/dev/null
    if [ -e /dev/disk/by-label/Ventoy ] && mount -t auto -o rw /dev/disk/by-label/Ventoy "$m" 2>/dev/null && [ -d "$m/provision" ]; then
        return 0
    fi
    if [ -e /dev/disk/by-label/Ventoy ] && mount -t auto -o ro /dev/disk/by-label/Ventoy "$m" 2>/dev/null && [ -d "$m/provision" ]; then
        return 0
    fi
    umount "$m" 2>/dev/null
    for s in /sys/class/block/*/dev; do
        [ -f "$s" ] || continue
        b=${s%/dev}; b=${b##*/}
        sz=$(cat "${s%/dev}/size" 2>/dev/null || echo 0)
        [ "$sz" -gt 500000 ] || continue
        mm=$(cat "$s")
        nd="/tmp/.vr-$b"
        rm -f "$nd"
        mknod "$nd" b "${mm%:*}" "${mm#*:}" 2>/dev/null || continue
        if mount -t vfat -o ro "$nd" "$m" 2>/dev/null || mount -t exfat -o ro "$nd" "$m" 2>/dev/null; then
            if [ -d "$m/provision" ]; then
                return 0
            fi
            umount "$m" 2>/dev/null
        fi
        rm -f "$nd"
    done
    return 1
}
vstick_writable() { # $1 = mounted stick; 0 iff logs may be written to it
    touch "$1/.wtest" 2>/dev/null && { rm -f "$1/.wtest"; return 0; }
    return 1
}
VMEOF
)
VMOUNT6=$(printf '%s\n' "$VMOUNT_FN" | sed 's/^/      /')

cat > "$AUTOINSTALL/$NAME.user-data" <<EOF
#cloud-config
# Autoinstall seed for ubuntu-26.04.1-live-server-amd64.iso via Ventoy auto_install (profile: $NAME).
# WARNING: storage below targets the LARGEST disk and wipes it.
# Initial console password for '$USER': see profiles/$NAME/profile.conf (SSH is key-only).
autoinstall:
  version: 1
  locale: en_US.UTF-8
  keyboard:
    layout: us
  identity:
    hostname: $HOSTNAME
    realname: $REALNAME
    username: $USER
    password: "$CRYPT"
  ssh:
    install-server: true
    allow-pw: false
$SSH_KEYS_YAML
  storage:
    config:
      - id: root-disk
        type: disk
        ptable: gpt
        wipe: superblock-recursive
        preserve: false
        grub_device: true
        match:
          size: "largest"
      - id: efi-part
        type: partition
        device: root-disk
        size: 1G
        flag: boot
        grub_device: true
      - id: root-part
        type: partition
        device: root-disk
        size: -1
      - id: root-fs
        type: format
        fstype: ext4
        volume: root-part
      - id: efi-fs
        type: format
        fstype: fat32
        volume: efi-part
      - id: root-mount
        type: mount
        path: /
        device: root-fs
      - id: efi-mount
        type: mount
        path: /boot/efi
        device: efi-fs
  packages:
    - curl
    - ca-certificates
    - openssl
    - git
    - python3
  user-data:
    timezone: America/Los_Angeles
  # End state: power off (never reboot). A reboot with the stick still plugged
  # would boot Ventoy again and, with autosel, silently re-run this autoinstall
  # and wipe the disk. After poweroff, power back on WITH the stick inserted
  # (or re-insert it): first boot mounts it as a normal writable USB disk and
  # provision-retry.service completes all provisioning from it.
  shutdown: poweroff
  # NOTHING touches the stick during the install: on a Ventoy boot the
  # read-only ISO device-mapper marks the whole stick disk read-only for the
  # entire live session, and no mount of the data partition (rw OR ro, via
  # node or dm copy) can succeed -- that is what aborted every install so far.
  # The only installer->target channel that always works is the seed itself
  # (ventoy injects it via CIDATA) plus plain writes to /target.
  late-commands:
    # Write the first-boot completion unit directly into the target. Pure local
    # writes: nothing here depends on the stick, so nothing can fail the
    # install. SSH keys are already installed by subiquity from the seed's
    # ssh.authorized-keys above.
    - |
      set -u
      mkdir -p /target/usr/local/sbin /target/etc/systemd/system/multi-user.target.wants
      cat > /target/usr/local/sbin/provision-retry.sh <<'RETRY'
      #!/usr/bin/env bash
      # Written by the autoinstall seed. Runs on every boot until /root/BOOTSTRAP-OK
      # exists. The Ventoy stick was unreachable during the install (read-only ISO
      # dm holds the whole disk); at first boot it is a normal writable USB disk.
      set -uo pipefail
      exec >>/var/log/ventoy-bootstrap.log 2>&1
      echo "[\$(date -Is)] provision-retry: completing provisioning and runtime acceptance"
      # Network self-report: the box records its own addresses so it can be found
      # over SSH even when discovery fails.
      ips=\$(hostname -I 2>/dev/null || true)
      echo "[\$(date -Is)] provision-retry: network ips=\$ips"
      { echo "firstboot \$(date -Is 2>/dev/null || date) profile=$NAME ips=\$ips"; ip -4 addr 2>/dev/null; ip route 2>/dev/null; } > /root/FIRSTBOOT-NETWORK 2>/dev/null || true
      rc=1
      if mkdir -p /mnt/ventoy && mount -t auto /dev/disk/by-label/Ventoy /mnt/ventoy 2>/dev/null && [ -d /mnt/ventoy/provision ]; then
      d=/mnt/ventoy/logs/firstboot-\$(date +%Y%m%d-%H%M%S)
      mkdir -p "\$d" 2>/dev/null || true
      echo "firstboot \$(date -Is 2>/dev/null || date) profile=$NAME ips=\$ips" >> /mnt/ventoy/logs/firstboot.log 2>/dev/null || true
      sync
      bash /mnt/ventoy/provision/bootstrap.sh --profile $NAME
      rc=\$?
      cp -a /root/FIRSTBOOT-NETWORK /var/log/ventoy-bootstrap.log "\$d/" 2>/dev/null || true
      sync
      umount /mnt/ventoy 2>/dev/null || true
      else
      echo "[\$(date -Is)] provision-retry: stick not mounted; re-insert the Ventoy stick and reboot, or run bootstrap.sh manually"
      fi
      printf '%s\n' "\$rc" > /root/BOOTSTRAP-RC 2>/dev/null || true
      exit "\$rc"
      RETRY
      chmod 755 /target/usr/local/sbin/provision-retry.sh
      # Passwordless sudo straight from the seed (profile-controlled): a pure
      # /target write, no stick dependency. Validated with target visudo when
      # curtin is available; on validation failure the fragment is removed and
      # bootstrap.sh re-attempts the same write at first boot.
      if [ $SUDO = 1 ]; then
      printf '%s ALL=(ALL) NOPASSWD: ALL\n' '$USER' > /target/etc/sudoers.d/$USER
      chmod 0440 /target/etc/sudoers.d/$USER
      if command -v curtin >/dev/null 2>&1 && ! curtin in-target --target=/target -- visudo -cf /etc/sudoers.d/$USER >/dev/null 2>&1; then
      echo "VENTOY-HOOK: sudoers fragment failed target visudo; removing" >&2
      rm -f /target/etc/sudoers.d/$USER
      fi
      fi
      cat > /target/etc/systemd/system/provision-retry.service <<'UNIT'
      [Unit]
      Description=Ventoy provision completion and runtime acceptance (needs the stick)
      ConditionPathExists=!/root/BOOTSTRAP-OK
      After=network-online.target multi-user.target
      Wants=network-online.target

      [Service]
      Type=oneshot
      RemainAfterExit=yes
      ExecStart=/usr/local/sbin/provision-retry.sh
      # 75min: baseline (30) + NVIDIA driver + CUDA toolkit installs fit inside
      # one first-boot run; a second boot retries anything incomplete.
      TimeoutStartSec=75min
      TimeoutStopSec=30s

      [Install]
      WantedBy=multi-user.target
      UNIT
      ln -sfn /etc/systemd/system/provision-retry.service \
      /target/etc/systemd/system/multi-user.target.wants/provision-retry.service
      printf 'staged-by-seed %s\n' "\$(date -Is 2>/dev/null || date)" > /target/root/BOOTSTRAP-STAGED
      echo "VENTOY-HOOK: first-boot completion unit installed from seed" >&2
  # Runs in the installer env on ANY fatal install error; non-zero exits are
  # ignored by subiquity. The stick is unreachable during a Ventoy install, so
  # evidence lands on the installed disk under /root/install-failure.
  error-commands:
    - |
      out=/target/root/install-failure
      mkdir -p "\$out" 2>/dev/null || true
      journalctl -b > "\$out/journal.txt" 2>/dev/null || true
      grep -aE 'VENTOY-HOOK|VENTOY-TRACE|latehook|provision-retry|subiquity' "\$out/journal.txt" > "\$out/ventoy-hooks.txt" 2>/dev/null || true
      tar -czf "\$out/installer-logs.tar.gz" /var/log/installer/ 2>/dev/null || true
      blkid > "\$out/blkid.txt" 2>&1 || true
      lsblk -o NAME,SIZE,FSTYPE,LABEL,MOUNTPOINT > "\$out/lsblk.txt" 2>&1 || true
      true
EOF

echo "== ventoy.json =="
python3 - "$STICK" <<'PY'
import json, pathlib, sys
stick = pathlib.Path(sys.argv[1])
profiles = sorted(p.name for p in (stick / "provision/profiles").iterdir() if p.is_dir())
if not profiles:
    raise SystemExit("no profiles found")
templates = [f"/ventoy/autoinstall/{n}.user-data" for n in profiles]
entry = {"image": "/ubuntu-26.04.1-live-server-amd64.iso", "template": templates}
if len(templates) == 1:
    entry["autosel"] = 1  # single profile: no boot-time menu
cfg = {
    # default boot entry = the MANUAL desktop ISO, so a reboot/power-on with the
    # stick still inserted can never silently re-run the autoinstall wipe
    "control": [{"VTOY_MENU_TIMEOUT": "10"},
                {"VTOY_DEFAULT_IMAGE": "/ubuntu-26.04.1-desktop-amd64.iso"}],
    "menu_alias": [
        {"image": "/ubuntu-26.04.1-live-server-amd64.iso",
         "alias": "Ubuntu 26.04.1 Server amd64 -- AUTOINSTALL (wipes largest disk; profile menu if >1)"},
        {"image": "/ubuntu-26.04.1-desktop-amd64.iso",
         "alias": "Ubuntu 26.04.1 Desktop amd64 (manual install, then run provision bootstrap --profile <name>)"},
        {"image": "/ubuntu-24.04.4-desktop-amd64.iso",
         "alias": "Ubuntu 24.04.4 Desktop amd64 (legacy)"},
    ],
    "auto_install": [entry],
}
path = stick / "ventoy/ventoy.json"
path.write_text(json.dumps(cfg, indent=4) + "\n")
print(f"{len(templates)} profile(s): {', '.join(profiles)}")
PY

echo "== done =="
echo "profile dir : $PDIR"
echo "user-data   : $AUTOINSTALL/$NAME.user-data"
if [ "$REFRESH_ONLY" = 0 ]; then echo "initial pwd : $PASSWORD"; fi
