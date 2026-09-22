#!/usr/bin/env bash
set -euo pipefail

if (( BASH_VERSINFO[0] < 4 )); then
  echo "Bash 4 or newer is required; found ${BASH_VERSION}." >&2
  exit 1
fi
printf '%-10s %s\n' bash "${BASH_VERSION}"

missing=0
for command_name in docker k3d kubectl helm argocd git curl openssl \
  base64 sed awk grep; do
  if command -v "$command_name" >/dev/null 2>&1; then
    printf '%-10s %s\n' "$command_name" "found"
  else
    printf '%-10s %s\n' "$command_name" "MISSING"
    missing=1
  fi
done

if (( missing )); then
  echo "Install the missing prerequisites before Phase 1." >&2
  exit 1
fi

if docker info >/dev/null 2>&1; then
  echo "Docker daemon is reachable."
else
  echo "Docker is installed, but its daemon is not reachable." >&2
  echo "Start Docker and confirm your user can access the Docker socket." >&2
  exit 1
fi

if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "Git working tree is available."
else
  echo "Run this check from inside the cloned lab repository." >&2
  exit 1
fi

echo "Prerequisite command check passed. Host-port checks are planned for Phase 11."
