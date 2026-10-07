#!/usr/bin/env bash
# Boot the omp guest VM under QEMU/KVM.
#   host 127.0.0.1:2222  -> guest :22   (ssh)
#   guest 10.0.2.2       -> host loopback (auth-broker at :8765 if you run host-link.sh)
#   optional: --share DIR mounts a host directory at /mnt/host in the guest (virtio-9p)
#
# Usage: ./run-vm.sh [--mem 8G] [--cpus 4] [--share /path/to/project] [--console]
set -euo pipefail

STATE="${OMP_VM_DIR:-$HOME/.local/share/omp-vm}"
MEM=8G
CPUS=4
SHARE=""
CONSOLE=0
SSH_PORT="${OMP_VM_SSH_PORT:-2222}"

while [ $# -gt 0 ]; do
  case "$1" in
    --mem)   MEM="$2"; shift 2 ;;
    --cpus)  CPUS="$2"; shift 2 ;;
    --share) SHARE="$(cd "$2" && pwd)"; shift 2 ;;
    --console) CONSOLE=1; shift ;;
    -h|--help) sed -n '2,7p' "$0"; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 1 ;;
  esac
done

OVERLAY="$STATE/omp-vm.qcow2"
SEED_ISO="$STATE/seed.iso"
[ -f "$OVERLAY" ] && [ -f "$SEED_ISO" ] || { echo "run ./create-vm.sh first" >&2; exit 1; }

ARCH="$(uname -m)"
case "$ARCH" in
  x86_64)  QEMU=qemu-system-x86_64;  MACHINE="q35" ;;
  aarch64) QEMU=qemu-system-aarch64; MACHINE="virt" ;;
  *) echo "unsupported host arch: $ARCH" >&2; exit 1 ;;
esac
command -v "$QEMU" >/dev/null || { echo "missing: $QEMU (apt install qemu-system)" >&2; exit 1; }

ACCEL=()
if [ -w /dev/kvm ]; then
  ACCEL=(-enable-kvm -cpu host)
else
  echo "warning: /dev/kvm not writable; running without KVM (slow). usermod -aG kvm \$USER" >&2
  ACCEL=(-cpu max)
fi
[ "$ARCH" = aarch64 ] && [ -w /dev/kvm ] && MACHINE="virt,gic-version=host"

# shellcheck disable=SC2054  # commas belong to QEMU option strings, not array separators
ARGS=(
  -machine "$MACHINE" "${ACCEL[@]}"
  -m "$MEM" -smp "$CPUS"
  -drive "file=$OVERLAY,if=virtio,format=qcow2,discard=unmap"
  -drive "file=$SEED_ISO,if=virtio,format=raw,readonly=on"
  -netdev "user,id=n0,hostfwd=tcp:127.0.0.1:${SSH_PORT}-:22"
  -device virtio-net-pci,netdev=n0
  -device virtio-rng-pci
)

if [ -n "$SHARE" ]; then
  # Guest: sudo mkdir -p /mnt/host && sudo mount -t 9p -o trans=virtio,version=9p2000.L hostshare /mnt/host
  ARGS+=(-virtfs "local,path=$SHARE,mount_tag=hostshare,security_model=mapped-xattr,id=share0")
fi

if [ "$CONSOLE" = 1 ]; then
  ARGS+=(-nographic -serial mon:stdio)
else
  ARGS+=(-display none -daemonize -pidfile "$STATE/qemu.pid" -serial "file:$STATE/console.log")
fi

echo "booting omp-vm: $QEMU ${ARGS[*]}" >&2
exec "$QEMU" "${ARGS[@]}"
