#!/usr/bin/env bash
# Run the omp sandbox container against a project directory.
# Credentials: either export a provider key (ANTHROPIC_API_KEY, OPENAI_API_KEY, OPENROUTER_API_KEY, ...)
# or use --broker to reuse the host omp's logins via `omp auth-broker serve`.
#
# Usage: ./run-container.sh [--broker] [--image omp-sandbox] <project-dir> [omp args...]
set -euo pipefail

IMAGE=omp-sandbox
BROKER=0
BROKER_PORT=8765

while [ $# -gt 0 ]; do
  case "$1" in
    --broker) BROKER=1; shift ;;
    --image)  IMAGE="$2"; shift 2 ;;
    -h|--help) sed -n '2,6p' "$0"; exit 0 ;;
    *) break ;;
  esac
done
[ $# -ge 1 ] || { echo "usage: $0 [--broker] <project-dir> [omp args...]" >&2; exit 1; }
PROJECT="$(cd "$1" && pwd)"; shift

docker image inspect "$IMAGE" >/dev/null 2>&1 || docker build -t "$IMAGE" "$(dirname "${BASH_SOURCE[0]}")"

ENVS=()
for v in ANTHROPIC_API_KEY ANTHROPIC_OAUTH_TOKEN OPENAI_API_KEY OPENROUTER_API_KEY GEMINI_API_KEY GROQ_API_KEY XAI_API_KEY; do
  [ -n "${!v:-}" ] && ENVS+=(-e "$v")
done

if [ "$BROKER" = 1 ]; then
  command -v omp >/dev/null || { echo "host omp not on PATH" >&2; exit 1; }
  # Containers reach the host through the bridge gateway, not 127.0.0.1, so the broker
  # must listen on that address. Token auth still gates every request.
  GW="$(docker network inspect bridge -f '{{(index .IPAM.Config 0).Gateway}}')"
  BROKER_BIND="$GW:$BROKER_PORT"
  if ! curl -fsS "http://$BROKER_BIND/v1/healthz" >/dev/null 2>&1; then
    echo "starting host auth-broker on $BROKER_BIND (log: /tmp/omp-auth-broker.log)" >&2
    nohup omp auth-broker serve --bind "$BROKER_BIND" >/tmp/omp-auth-broker.log 2>&1 &
    for _ in $(seq 1 20); do curl -fsS "http://$BROKER_BIND/v1/healthz" >/dev/null 2>&1 && break; sleep 1; done
  fi
  ENVS+=(-e "OMP_AUTH_BROKER_URL=http://$GW:$BROKER_PORT"
         -e "OMP_AUTH_BROKER_TOKEN=$(omp auth-broker token)")
fi

# Persist guest sessions/config across runs in a named volume.
exec docker run --rm -it \
  -v "$PROJECT:/work" \
  -v omp-sandbox-home:/home/omp/.omp \
  ${ENVS[@]+"${ENVS[@]}"} \
  "$IMAGE" "$@"
