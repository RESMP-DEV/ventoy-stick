#!/usr/bin/env bash
# One-shot stick assembly (macOS): reformat the Ventoy data partition to exFAT
# (so the Mac can write it; Ventoy scans any supported FS) and copy everything:
# ISOs from isos/ + backup/, then the staging stick tree. The Ventoy boot
# partition (VTOYEFI) is untouched. Everything on the data partition is DESTROYED.
# Set DISKPART (e.g. disk4s1) to skip auto-detection by volume name.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
MNT=/Volumes/Ventoy

DISKPART=${DISKPART:-$(diskutil info Ventoy 2>/dev/null | awk '/Device Node/ {print $3}')}
[ -n "$DISKPART" ] || { echo "Ventoy volume not found; set DISKPART=diskNsM explicitly" >&2; exit 1; }
echo "ERASING $DISKPART (all data on that partition will be lost) in 5s; Ctrl-C to abort"
sleep 5

echo "== unmounting =="
diskutil unmount "$DISKPART" 2>/dev/null || diskutil unmount force "$DISKPART" 2>/dev/null || true

echo "== reformatting $DISKPART as exFAT (label Ventoy) =="
diskutil eraseVolume exfat Ventoy "$DISKPART"

echo "== waiting for mount =="
for i in $(seq 1 15); do mount | grep -q " $MNT " && break; sleep 2; done
mount | grep " $MNT " || { echo "not mounted" >&2; exit 1; }
df -h "$MNT"

echo "== copying ISOs =="
rsync -a "$ROOT/isos/" "$MNT/"
[ -f "$ROOT/backup/ubuntu-24.04.4-desktop-amd64.iso" ] && rsync -a "$ROOT/backup/ubuntu-24.04.4-desktop-amd64.iso" "$MNT/"

echo "== copying provisioning tree =="
rsync -a --exclude .DS_Store "$ROOT/stick/" "$MNT/"

echo "== manifest =="
( cd "$MNT" && find . -type f -not -name MANIFEST.sha256 \
    -not -path './.fseventsd/*' -not -path './.Spotlight-V100/*' \
    -print0 | xargs -0 shasum -a 256 ) > "$MNT/MANIFEST.sha256" 2>/dev/null || true
echo "manifest entries: $(wc -l < "$MNT/MANIFEST.sha256" | tr -d ' ')"

echo "== final listing =="
ls -lh "$MNT/"
df -h "$MNT"
echo "ASSEMBLE_DONE"
echo "verify ISOs: cd $MNT && grep '26.04.1-' SHA256SUMS | shasum -a 256 -c -"
