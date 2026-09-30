#!/usr/bin/env bash
# Evidence dump for the subiquity error shell (run as root in the live/installer
# environment after an installer failure; the stick must be mounted, see the
# one-liner in the README). Collects everything needed to diagnose a
# pre-install crash: installer logs, cloud-init state, the tty1 screen buffer
# (what the error screen showed), journal, crash files, and device inventory.
# Writes to <stick>/logs/error-shell-<ts>/ and exits 0 always.
set -uo pipefail
VTOY_MNT=${VTOY_MNT:-/mnt/v}
out=${1:-}
ts=$(date +%Y%m%d-%H%M%S 2>/dev/null || echo ts)

if ! mountpoint -q "$VTOY_MNT" 2>/dev/null; then
    mkdir -p "$VTOY_MNT" 2>/dev/null || true
    dev=/dev/disk/by-label/Ventoy
    [ -e "$dev" ] || dev=$(findfs LABEL=Ventoy 2>/dev/null || true)
    [ -n "${dev:-}" ] && [ -e "$dev" ] && mount -t auto "$dev" "$VTOY_MNT" 2>/dev/null
fi

if [ -n "$out" ]; then
    d=$out
    mkdir -p "$d" 2>/dev/null || true
elif [ -d "$VTOY_MNT/provision" ]; then
    d="$VTOY_MNT/logs/error-shell-$ts"
    mkdir -p "$d" 2>/dev/null || { echo "cannot create $d" >&2; exit 1; }
else
    d="/target/root/error-shell-$ts"
    [ -d /target/root ] || d="/root/error-shell-$ts"
    mkdir -p "$d"
    echo "WARN: stick not mounted; writing to $d instead" >&2
fi

echo "dumping to $d"
cp -a /var/log/installer "$d/" 2>/dev/null || true
cp -a /var/crash "$d/" 2>/dev/null || true
journalctl -b > "$d/journal.txt" 2>&1 || true
grep -aE 'VENTOY|subiquity|cloud-init|autoinstall' "$d/journal.txt" > "$d/markers-grep.txt" 2>/dev/null || true
dmesg > "$d/dmesg.txt" 2>&1 || true
# the visible error screen: tty1's kernel screen buffer
cat /dev/vcs1 > "$d/tty1-screen.txt" 2>/dev/null \
    || fold -w 200 /dev/vcsa1 2>/dev/null > "$d/tty1-screen.txt" \
    || true
cloud-init status --long > "$d/cloud-init-status.txt" 2>&1 || true
cp -a /var/lib/cloud/instances "$d/cloud-instances" 2>/dev/null || true
lsblk -o NAME,SIZE,FSTYPE,LABEL,MOUNTPOINT > "$d/lsblk.txt" 2>&1 || true
blkid > "$d/blkid.txt" 2>&1 || true
cat /proc/cmdline > "$d/cmdline.txt" 2>/dev/null || true
# network state of the live session (was DHCP ever up?)
ip -4 addr > "$d/ip-addr.txt" 2>&1 || true
free -m > "$d/mem.txt" 2>&1 || true
sync
echo "DONE: $d"
[ -d "$VTOY_MNT/provision" ] && umount "$VTOY_MNT" 2>/dev/null
exit 0
