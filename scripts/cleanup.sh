#!/usr/bin/env bash
set -euo pipefail

for cluster in argocd-hub spoke-01 spoke-02; do
  k3d cluster delete "$cluster" 2>/dev/null || true
done
docker rm -f moto 2>/dev/null || true
docker network rm argo-lab 2>/dev/null || true
echo "Removed the three lab clusters, Moto, and the argo-lab network."
