#!/usr/bin/env bash
set -euo pipefail

missing=0
for command_name in docker k3d kubectl helm argocd; do
  if command -v "$command_name" >/dev/null 2>&1; then
    printf '%-8s %s\n' "$command_name" "found"
  else
    printf '%-8s %s\n' "$command_name" "MISSING"
    missing=1
  fi
done

if (( missing )); then
  echo "Install the missing prerequisites before Phase 1." >&2
  exit 1
fi

docker info >/dev/null
echo "Docker daemon is reachable."
