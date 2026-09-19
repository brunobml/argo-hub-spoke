#!/usr/bin/env bash
set -euo pipefail

network=argo-lab
docker network inspect "$network" >/dev/null 2>&1 || docker network create "$network" >/dev/null

create_cluster() {
  local name=$1 port=$2
  local -a extra_args=()
  if k3d cluster list --no-headers | awk '{print $1}' | grep -qx "$name"; then
    echo "$name already exists"
    return
  fi
  if [[ "$name" == argocd-hub ]]; then
    extra_args=(
      --port "127.0.0.1:80:80@loadbalancer"
      --port "127.0.0.1:443:443@loadbalancer"
    )
  fi
  k3d cluster create "$name" \
    --network "$network" \
    --api-port "127.0.0.1:${port}" \
    --servers 1 \
    --agents 0 \
    "${extra_args[@]}" \
    --wait
}

create_cluster argocd-hub 6550
create_cluster spoke-01 6551
create_cluster spoke-02 6552

kubectl config get-contexts
