#!/usr/bin/env bash
# Ventoy provision late-command hook. Runs in the INSTALLER environment during
# autoinstall late-commands (NOT chrooted; /target = the freshly installed OS,
# /mnt/ventoy = the stick's data partition, mounted by the late-command that
# invoked this script).
#
# Contract: provisioning failures are recorded without aborting the install,
# and the stick is flushed and unmounted after logs are saved (any
# late-command failure would kill the install, stranding its logs in live RAM).
#
# Modes:
#   latehook.sh --profile NAME        normal install-time path
#   latehook.sh --on-error            rescue path from autoinstall error-commands
#
# Normal path:
#   1. SSH authorized_keys fallback straight from the profile, BEFORE anything
#      else can fail: SSH must work on first boot even if bootstrap dies.
#   2. provision-retry systemd unit (full provisioning and acceptance run at
#      first boot; install-time staging does not create BOOTSTRAP-OK).
#   3. bootstrap.sh --chrooted --no-baseline (baseline tools move to first
#      boot: they are network-heavy with no timeouts and must not stall the
#      unattended window). Exit code recorded to /target/root/BOOTSTRAP-RC.
#   4. Logs + RESULT marker copied to the stick, stick unmounted.
set -uo pipefail

PROFILE=default
MODE=run
while [ $# -gt 0 ]; do
    case "$1" in
        --profile) shift; PROFILE=${1:?--profile needs a name} ;;
        --on-error) MODE=on-error ;;
        *) echo "latehook: unknown arg: $1" >&2 ;;
    esac
    shift
done

TARGET=${TARGET:-/target}
VTOY_MNT=${VTOY_MNT:-/mnt/ventoy}
BOOTSTRAP_TIMEOUT=${BOOTSTRAP_TIMEOUT:-600}
HOOKDIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
mkdir -p "$TARGET/root" 2>/dev/null || true
HL="$TARGET/root/latehook.log"

# logs to file AND stderr; stdout stays clean for $( ) capture
hlog() { printf '[%s] %s\n' "$(date -Is 2>/dev/null || date)" "$*" | tee -a "$HL" 2>/dev/null >&2 || printf '[%s] %s\n' "$(date)" "$*" >&2; }

mount_stick() {
    # Ventoy: the read-only ISO dm marks the whole stick disk read-only during
    # the live session, so rw mounts cannot succeed; mount read-only (the
    # install-time payload is read-only by design). by-label first, then a
    # vfat/exfat-restricted scan over all block devices including ventoy's dm.
    mkdir -p "$VTOY_MNT" 2>/dev/null || true
    local d b sz mm nd
    if [ -e /dev/disk/by-label/Ventoy ]; then
        if mount -t auto -o rw /dev/disk/by-label/Ventoy "$VTOY_MNT" 2>/dev/null \
            || mount -t auto -o ro /dev/disk/by-label/Ventoy "$VTOY_MNT" 2>/dev/null; then
            [ -d "$VTOY_MNT/provision" ] && return 0
            umount "$VTOY_MNT" 2>/dev/null || true
        fi
    fi
    for d in /sys/class/block/*/dev; do
        [ -f "$d" ] || continue
        b=${d%/dev}; b=${b##*/}
        sz=$(cat "${d%/dev}/size" 2>/dev/null || echo 0)
        [ "$sz" -gt 500000 ] || continue
        mm=$(cat "$d")
        nd="/tmp/.vr-$b"
        rm -f "$nd"
        mknod "$nd" b "${mm%:*}" "${mm#*:}" 2>/dev/null || continue
        if mount -t vfat -o ro "$nd" "$VTOY_MNT" 2>/dev/null || mount -t exfat -o ro "$nd" "$VTOY_MNT" 2>/dev/null; then
            [ -d "$VTOY_MNT/provision" ] && return 0
            umount "$VTOY_MNT" 2>/dev/null || true
        fi
        rm -f "$nd"
    done
    return 1
}

stick_logdir() {
    # echo the stick log dir; empty on failure. During a Ventoy install the
    # stick is read-only (see mount_stick): logs then stay under $TARGET and
    # first boot copies them when the stick is writable again.
    if ! mountpoint -q "$VTOY_MNT" 2>/dev/null; then
        mount_stick || { hlog "WARN: cannot mount stick for log copy"; return 1; }
    fi
    if [ ! -d "$VTOY_MNT/provision" ]; then
        hlog "WARN: $VTOY_MNT has no provision/ (wrong partition mounted?)"
        return 1
    fi
    if ! touch "$VTOY_MNT/.wtest" 2>/dev/null; then
        hlog "stick is read-only (Ventoy install); logs remain under $TARGET/root and /var/log"
        return 1
    fi
    rm -f "$VTOY_MNT/.wtest"
    local d
    d="$VTOY_MNT/logs/$PROFILE-$(date +%Y%m%d-%H%M%S 2>/dev/null || echo ts)"
    mkdir -p "$d" 2>/dev/null || { hlog "WARN: cannot create stick log dir"; return 1; }
    printf '%s' "$d"
}

collect_to_stick() { # destdir
    local d=$1 f
    for f in \
        "$TARGET/root/latehook.log" \
        "$TARGET/root/BOOTSTRAP-RC" \
        "$TARGET/root/BOOTSTRAP-FAILED" \
        "$TARGET/root/BOOTSTRAP-OK" \
        "$TARGET/root/BOOTSTRAP-STAGED" \
        "$TARGET/var/log/ventoy-bootstrap.log" \
        "$TARGET/root/install-failure"
    do
        [ -e "$f" ] && cp -R "$f" "$d/" 2>/dev/null
    done
    return 0
}

if [ "$MODE" = on-error ]; then
    # ---- rescue path (from error-commands; failures here are ignored by subiquity)
    hlog "=== latehook on-error rescue ==="
    OUT="$TARGET/root/install-failure"
    mkdir -p "$OUT" 2>/dev/null || true
    journalctl -b > "$OUT/journal.txt" 2>/dev/null || true
    tar -czf "$OUT/installer-logs.tar.gz" /var/log/installer/ 2>/dev/null || true
    blkid > "$OUT/blkid.txt" 2>&1 || true
    lsblk -o NAME,SIZE,FSTYPE,LABEL,MOUNTPOINT > "$OUT/lsblk.txt" 2>&1 || true
    d=$(stick_logdir) && { collect_to_stick "$d"; sync; umount "$VTOY_MNT" 2>/dev/null || true; }
    exit 0
fi

# ---- normal path ----------------------------------------------------------
hlog "=== latehook start: profile=$PROFILE hookdir=$HOOKDIR ==="

PROFILE_DIR="$HOOKDIR/profiles/$PROFILE"
if [ ! -d "$PROFILE_DIR" ]; then
    hlog "FATAL: profile dir $PROFILE_DIR missing; keys fallback and bootstrap skipped"
else
    TARGET_USER=$(sed -n 's/^TARGET_USER="\([^"]*\)"$/\1/p' "$PROFILE_DIR/profile.conf" 2>/dev/null | head -1)
    TARGET_USER=${TARGET_USER:-provision}

    # 1) SSH keys fallback: independent of everything downstream
    uid=$(awk -F: -v u="$TARGET_USER" '$1==u{print $3}' "$TARGET/etc/passwd" 2>/dev/null)
    gid=$(awk -F: -v u="$TARGET_USER" '$1==u{print $4}' "$TARGET/etc/passwd" 2>/dev/null)
    uid=${uid:-1000}; gid=${gid:-1000}
    SSHDIR="$TARGET/home/$TARGET_USER/.ssh"
    if mkdir -p "$SSHDIR" 2>/dev/null; then
        chmod 700 "$SSHDIR" 2>/dev/null || true
        touch "$SSHDIR/authorized_keys" 2>/dev/null || true
        chmod 600 "$SSHDIR/authorized_keys" 2>/dev/null || true
        for pub in "$PROFILE_DIR"/ssh/*.pub; do
            [ -f "$pub" ] || continue
            key=$(cat "$pub" 2>/dev/null) || continue
            grep -qxF "$key" "$SSHDIR/authorized_keys" 2>/dev/null || printf '%s\n' "$key" >> "$SSHDIR/authorized_keys"
        done
        chown -R "$uid:$gid" "$SSHDIR" 2>/dev/null || true
        hlog "SSH authorized_keys fallback installed for $TARGET_USER (uid=$uid)"
    else
        hlog "WARN: cannot create $SSHDIR; SSH fallback skipped"
    fi

    # 2) first-boot retry unit (ConditionPathExists=!/root/BOOTSTRAP-OK)
    if mkdir -p "$TARGET/etc/systemd/system/multi-user.target.wants" "$TARGET/usr/local/sbin" 2>/dev/null; then
        cat > "$TARGET/usr/local/sbin/provision-retry.sh" <<EOF
#!/usr/bin/env bash
# Written by latehook.sh; full provisioning runs until BOOTSTRAP-OK exists.
set -uo pipefail
exec >>/var/log/ventoy-bootstrap.log 2>&1
echo "[\$(date -Is)] provision-retry: completing provisioning and runtime acceptance"
# Network self-report: the box records its own addresses at every boot until
# completion, so it can be located over SSH even when discovery fails (no
# avahi, wrong subnet guess, scan miss). Local file + best-effort stick copy.
ips=\$(hostname -I 2>/dev/null || true)
echo "[\$(date -Is)] provision-retry: network ips=\$ips"
{ echo "firstboot \$(date -Is 2>/dev/null || date) profile=$PROFILE ips=\$ips"; ip -4 addr 2>/dev/null; ip route 2>/dev/null; } > /root/FIRSTBOOT-NETWORK 2>/dev/null || true
mkdir -p /mnt/ventoy-fb
if mount -t auto /dev/disk/by-label/Ventoy /mnt/ventoy-fb 2>/dev/null && [ -d /mnt/ventoy-fb/provision ]; then
    echo "firstboot \$(date -Is 2>/dev/null || date) profile=$PROFILE ips=\$ips" >> /mnt/ventoy-fb/logs/firstboot.log 2>/dev/null || true
    sync
    umount /mnt/ventoy-fb 2>/dev/null || true
fi
if [ -f /root/provision-copy/bootstrap.sh ] && [ -f /root/provision-copy/.copy-complete ]; then
    bash /root/provision-copy/bootstrap.sh --profile $PROFILE
    rc=\$?
elif mkdir -p /mnt/ventoy && mount -t auto /dev/disk/by-label/Ventoy /mnt/ventoy 2>/dev/null; then
    bash /mnt/ventoy/provision/bootstrap.sh --profile $PROFILE
    rc=\$?
    sync
    umount /mnt/ventoy 2>/dev/null || true
else
    echo "[\$(date -Is)] provision-retry: no /root/provision-copy and stick not mountable; re-run bootstrap.sh manually"
    rc=1
fi
printf '%s\n' "\$rc" > /root/BOOTSTRAP-RC
# Sync install-time logs to the stick: it was READ-ONLY during the Ventoy
# install (the read-only ISO dm marks the whole disk ro), so the logs written
# under /root and /var/log only reach the stick now, when it is writable.
if mkdir -p /mnt/ventoy-lb && mount -t auto -o rw /dev/disk/by-label/Ventoy /mnt/ventoy-lb 2>/dev/null && [ -d /mnt/ventoy-lb/provision ]; then
    d=/mnt/ventoy-lb/logs/firstboot-\$(date +%Y%m%d-%H%M%S)
    if mkdir -p "\$d"; then
        cp -a /root/latehook.log /root/BOOTSTRAP-RC /root/BOOTSTRAP-OK /root/BOOTSTRAP-FAILED /root/FIRSTBOOT-NETWORK "\$d/" 2>/dev/null || true
        cp -a /var/log/ventoy-bootstrap.log "\$d/" 2>/dev/null || true
        sync
    fi
    umount /mnt/ventoy-lb 2>/dev/null || true
fi
exit "\$rc"
EOF
        chmod 755 "$TARGET/usr/local/sbin/provision-retry.sh" 2>/dev/null || true
        cat > "$TARGET/etc/systemd/system/provision-retry.service" <<'EOF'
[Unit]
Description=Ventoy provision completion and runtime acceptance
ConditionPathExists=!/root/BOOTSTRAP-OK
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/provision-retry.sh
TimeoutStartSec=45min
TimeoutStopSec=30s

[Install]
WantedBy=multi-user.target
EOF
        ln -sfn /etc/systemd/system/provision-retry.service \
            "$TARGET/etc/systemd/system/multi-user.target.wants/provision-retry.service" 2>/dev/null || true
        hlog "provision-retry unit installed (conditional on missing /root/BOOTSTRAP-OK)"
    else
        hlog "WARN: cannot write retry unit into $TARGET/etc"
    fi
fi

# 3) bootstrap in the chroot; NEVER fatal to the install
if [ ! -f "$TARGET/root/provision-copy/.copy-complete" ]; then
    hlog "FATAL: payload copy incomplete; first-boot retry requires the stick"
    printf 'copy-incomplete\n' > "$TARGET/root/BOOTSTRAP-RC" 2>/dev/null || true
elif command -v curtin >/dev/null 2>&1; then
    hlog "running bootstrap --chrooted --no-baseline"
    if timeout --kill-after=30 "$BOOTSTRAP_TIMEOUT" curtin in-target --target="$TARGET" -- bash /root/provision-copy/bootstrap.sh --chrooted --profile "$PROFILE" --no-baseline; then
        rc=0
    else
        rc=$?
    fi
    printf '%s\n' "$rc" > "$TARGET/root/BOOTSTRAP-RC" 2>/dev/null || true
    hlog "bootstrap rc=$rc (recorded in /root/BOOTSTRAP-RC)"
    if [ "$rc" -ne 0 ]; then
        printf 'rc=%s stage=install-bootstrap profile=%s\n' "$rc" "$PROFILE" >> "$TARGET/root/BOOTSTRAP-FAILED" 2>/dev/null || true
    fi
else
    hlog "FATAL: curtin not on PATH; bootstrap not run (first-boot retry will handle it)"
    echo "nocurtin" > "$TARGET/root/BOOTSTRAP-RC" 2>/dev/null || true
fi

# 4) logs + verdict to the stick, then unmount
d=$(stick_logdir)
if [ -n "$d" ]; then
    collect_to_stick "$d"
    { echo "profile=$PROFILE date=$(date -Is 2>/dev/null) rc=$(cat "$TARGET/root/BOOTSTRAP-RC" 2>/dev/null || echo unknown)"; } \
        > "$d/RESULT" 2>/dev/null || true
    hlog "logs + RESULT written to stick: $d"
    sync
    umount "$VTOY_MNT" 2>/dev/null || true
else
    hlog "WARN: logs could not be copied to stick (they remain under $TARGET/root and $TARGET/var/log)"
fi

hlog "=== latehook done ==="
exit 0
