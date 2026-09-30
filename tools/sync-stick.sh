#!/usr/bin/env bash
# Sync the staging stick tree onto the physical Ventoy stick and regenerate
# MANIFEST.sha256. ISOs and SHA256SUMS are EXCLUDED from --delete (they live
# only on the stick; a past version of this script deleted them).
# Portable: VENTOY_MOUNT defaults to /Volumes/Ventoy (macOS) or
# /media/$USER/Ventoy (Linux); set it explicitly if yours differs.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
MNT=${VENTOY_MOUNT:-}
if [ -z "$MNT" ]; then
    case "$(uname -s)" in
        Darwin) MNT=/Volumes/Ventoy ;;
        Linux)  MNT=/media/$USER/Ventoy ;;
    esac
fi
[ -n "$MNT" ] || { echo "cannot infer mount point; set VENTOY_MOUNT" >&2; exit 1; }

if [ "$(uname -s)" = Darwin ] && ! [ -d "$MNT" ]; then
    diskutil info Ventoy >/dev/null 2>&1 && diskutil mount "$(diskutil info Ventoy | awk '/Device Node/ {print $3}')" 2>/dev/null || true
fi
[ -d "$MNT" ] || { echo "stick not mounted at $MNT (plug it in / mount it)" >&2; exit 1; }

# guard against rsync --delete into the wrong volume: require an external
# exFAT/FAT device whose volume name is Ventoy (macOS), or a non-root fs (Linux)
if [ "$(uname -s)" = Darwin ]; then
    vol_info=$(diskutil info "$MNT" 2>/dev/null || true)
    echo "$vol_info" | grep -q 'Volume Name: *Ventoy' || { echo "refusing: volume at $MNT is not named Ventoy" >&2; exit 1; }
    echo "$vol_info" | grep -qE 'Protocol: *USB' || { echo "refusing: $MNT is not a USB device" >&2; exit 1; }
    echo "$vol_info" | grep -qE 'File System Personality: *ExFAT' || echo "WARN: $MNT is not exFAT (continuing)" >&2
else
    [ "$(stat -c %d "$MNT")" != "$(stat -c %d /)" ] || { echo "refusing: $MNT is on the root filesystem" >&2; exit 1; }
fi
if command -v sha256sum >/dev/null; then H="sha256sum"; else H="shasum -a 256"; fi
df -h "$MNT" 2>/dev/null || true

echo "== rsync stick tree (with --delete; ISOs and SHA256SUMS are excluded so they survive) =="
rsync -rlt --delete --exclude .DS_Store --exclude MANIFEST.sha256 \
    --exclude '/logs/' --exclude '/.fseventsd/' --exclude '/.Spotlight-V100/' --exclude '/.Trashes/' \
    --exclude '*.iso' --exclude 'SHA256SUMS' \
    "$ROOT/stick/" "$MNT/"

echo "== manifest =="
( cd "$MNT" && find . -type f -not -name MANIFEST.sha256 \
    -not -path './logs/*' -not -path './.fseventsd/*' -not -path './.Spotlight-V100/*' -not -path './.Trash*' \
    -not -name .DS_Store -print0 | xargs -0 $H ) > "$MNT/MANIFEST.sha256"
echo "manifest entries: $(wc -l < "$MNT/MANIFEST.sha256" | tr -d ' ')"

echo "== profiles on stick =="
ls "$MNT/provision/profiles/" 2>/dev/null || echo "(no profiles!)"
df -h "$MNT" 2>/dev/null || true
echo "SYNC_DONE"
sync
