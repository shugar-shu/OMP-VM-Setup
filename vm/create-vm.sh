#!/usr/bin/env bash
# Create a disposable omp guest VM: Ubuntu cloud image + qcow2 overlay + cloud-init seed.
# Idempotent: re-running reuses the downloaded base image and rebuilds the overlay/seed.
#
# Usage: ./create-vm.sh [--disk 40G] [--key ~/.ssh/id_ed25519.pub] [--release noble]
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE="${OMP_VM_DIR:-$HOME/.local/share/omp-vm}"
DISK=40G
RELEASE=noble            # Ubuntu 24.04 LTS; cloud-init + KVM-friendly
KEY=""

while [ $# -gt 0 ]; do
  case "$1" in
    --disk)    DISK="$2"; shift 2 ;;
    --key)     KEY="$2"; shift 2 ;;
    --release) RELEASE="$2"; shift 2 ;;
    -h|--help) sed -n '2,6p' "$0"; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 1 ;;
  esac
done

need() { command -v "$1" >/dev/null 2>&1 || { echo "missing: $1 ($2)" >&2; exit 1; }; }
need qemu-img "apt install qemu-utils"
need curl "apt install curl"

# Seed ISO builder: first available of cloud-localds / genisoimage / xorriso / mkisofs.
if command -v cloud-localds >/dev/null;  then SEED=cloud-localds
elif command -v genisoimage >/dev/null;  then SEED=genisoimage
elif command -v xorriso >/dev/null;      then SEED=xorriso
elif command -v mkisofs >/dev/null;      then SEED=mkisofs
else echo "missing: cloud-localds (apt install cloud-image-utils) or genisoimage/xorriso" >&2; exit 1
fi

if [ -z "$KEY" ]; then
  for k in "$HOME/.ssh/id_ed25519.pub" "$HOME/.ssh/id_rsa.pub"; do
    [ -f "$k" ] && { KEY="$k"; break; }
  done
fi
[ -n "$KEY" ] && [ -f "$KEY" ] || { echo "no SSH public key; pass --key or run ssh-keygen -t ed25519" >&2; exit 1; }

mkdir -p "$STATE"
ARCH="$(uname -m)"
case "$ARCH" in
  x86_64)  IMG_ARCH=amd64 ;;
  aarch64) IMG_ARCH=arm64 ;;
  *) echo "unsupported host arch: $ARCH" >&2; exit 1 ;;
esac

BASE="$STATE/ubuntu-${RELEASE}-${IMG_ARCH}.img"
OVERLAY="$STATE/omp-vm.qcow2"
SEED_ISO="$STATE/seed.iso"
URL="https://cloud-images.ubuntu.com/${RELEASE}/current/${RELEASE}-server-cloudimg-${IMG_ARCH}.img"

if [ ! -f "$BASE" ]; then
  echo "downloading $URL"
  curl -fL --progress-bar -o "$BASE.part" "$URL" && mv "$BASE.part" "$BASE"
fi

echo "creating overlay $OVERLAY ($DISK)"
rm -f "$OVERLAY"
qemu-img create -q -f qcow2 -b "$BASE" -F qcow2 "$OVERLAY" "$DISK"

# Render cloud-init with the SSH key substituted.
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PUBKEY="$(cat "$KEY")"
sed "s|__SSH_PUBKEY__|$PUBKEY|" "$HERE/cloud-init/user-data" > "$TMP/user-data"
cp "$HERE/cloud-init/meta-data" "$TMP/meta-data"

echo "building seed ISO with $SEED"
case "$SEED" in
  cloud-localds) cloud-localds "$SEED_ISO" "$TMP/user-data" "$TMP/meta-data" ;;
  genisoimage|mkisofs) "$SEED" -quiet -output "$SEED_ISO" -volid cidata -joliet -rock "$TMP/user-data" "$TMP/meta-data" ;;
  xorriso) xorriso -as mkisofs -quiet -output "$SEED_ISO" -volid cidata -joliet -rock "$TMP/user-data" "$TMP/meta-data" ;;
esac

cat <<EOF

VM prepared in $STATE
  base    : $BASE
  overlay : $OVERLAY
  seed    : $SEED_ISO
Next: ./run-vm.sh          (first boot runs cloud-init and installs omp; ~2-4 min)
      ssh -p 2222 omp@127.0.0.1 'cat omp-install.log'
EOF
