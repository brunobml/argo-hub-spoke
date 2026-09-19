#!/usr/bin/env bash
set -euo pipefail

name=${1:-}
port=${2:-}
[[ "$name" =~ ^spoke-[a-z0-9-]+$ && "$port" =~ ^[0-9]+$ ]] || {
  echo "usage: $0 spoke-03 6553" >&2
  exit 2
}

docker network inspect argo-lab >/dev/null 2>&1 || docker network create argo-lab >/dev/null
k3d cluster create "$name" --network argo-lab --api-port "127.0.0.1:${port}" \
  --servers 1 --agents 0 --wait
./scripts/register-clusters.sh "$name"
./scripts/install-eso.sh "$name"
./scripts/harden-rbac.sh "$name"

echo "$name is registered. ApplicationSet should create demo-app-${name} automatically."
