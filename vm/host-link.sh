#!/usr/bin/env bash
# Wire the HOST omp to the GUEST omp.
#   1. registers the guest as an omp SSH host so host sessions can `read ssh://omp-vm/...`
#   2. (optional, --broker) starts the host auth-broker and points the guest omp at it,
#      so the guest reuses the host's logins without copying API keys into the VM.
#
# Usage: ./host-link.sh [--broker] [--port 2222] [--user omp]
set -euo pipefail

SSH_PORT="${OMP_VM_SSH_PORT:-2222}"
USER_="omp"
BROKER=0
BROKER_BIND="127.0.0.1:8765"
HOST_NAME="omp-vm"

while [ $# -gt 0 ]; do
  case "$1" in
    --broker) BROKER=1; shift ;;
    --port)   SSH_PORT="$2"; shift 2 ;;
    --user)   USER_="$2"; shift 2 ;;
    -h|--help) sed -n '2,7p' "$0"; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 1 ;;
  esac
done

command -v omp >/dev/null || { echo "host omp not on PATH" >&2; exit 1; }
SSH=(ssh -p "$SSH_PORT" -o StrictHostKeyChecking=accept-new -o ConnectTimeout=5 "$USER_@127.0.0.1")

echo "waiting for guest ssh on 127.0.0.1:$SSH_PORT"
for _ in $(seq 1 60); do
  if "${SSH[@]}" true 2>/dev/null; then break; fi
  sleep 5
done
"${SSH[@]}" true || { echo "guest ssh unreachable" >&2; exit 1; }

# shellcheck disable=SC2088  # tilde is expanded by the remote shell, not locally
echo "guest omp: $("${SSH[@]}" '~/.local/bin/omp --version 2>&1 || cat ~/omp-install.log')"

# 1. Register in the host omp's SSH host list (user scope).
omp ssh add "$HOST_NAME" --host 127.0.0.1 --port "$SSH_PORT" --user "$USER_" \
  --desc "omp guest VM" --scope user >/dev/null
echo "registered ssh host '$HOST_NAME' (host omp can read ssh://$HOST_NAME/home/$USER_/...)"

# 2. Optional broker link.
if [ "$BROKER" = 1 ]; then
  if ! curl -fsS "http://$BROKER_BIND/v1/healthz" >/dev/null 2>&1; then
    echo "starting host auth-broker on $BROKER_BIND (log: /tmp/omp-auth-broker.log)"
    nohup omp auth-broker serve --bind "$BROKER_BIND" >/tmp/omp-auth-broker.log 2>&1 &
    for _ in $(seq 1 20); do
      curl -fsS "http://$BROKER_BIND/v1/healthz" >/dev/null 2>&1 && break
      sleep 1
    done
  fi
  TOKEN="$(omp auth-broker token)"
  # Guest reaches host loopback at 10.0.2.2 (QEMU user-mode network).
  GUEST_URL="http://10.0.2.2:${BROKER_BIND##*:}"
  "${SSH[@]}" "mkdir -p ~/.omp/agent && umask 077 && \
    sed -i '/^OMP_AUTH_BROKER_/d' ~/.omp/agent/.env 2>/dev/null; \
    printf 'OMP_AUTH_BROKER_URL=%s\nOMP_AUTH_BROKER_TOKEN=%s\n' '$GUEST_URL' '$TOKEN' >> ~/.omp/agent/.env"
  echo "guest configured for broker $GUEST_URL"
  echo "verify: ssh -p $SSH_PORT $USER_@127.0.0.1 '~/.local/bin/omp auth-broker status'"
fi

cat <<EOF

Done. Try from the host:
  omp read ssh://$HOST_NAME/home/$USER_/omp-install.log
  ssh -p $SSH_PORT $USER_@127.0.0.1 -t '~/.local/bin/omp'
EOF
