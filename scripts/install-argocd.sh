#!/usr/bin/env bash
set -euo pipefail

context=k3d-argocd-hub
version=${ARGO_CD_VERSION:-v3.1.8}
manifest="https://raw.githubusercontent.com/argoproj/argo-cd/${version}/manifests/install.yaml"

kubectl --context "$context" create namespace argocd --dry-run=client -o yaml | \
  kubectl --context "$context" apply -f -
kubectl --context "$context" apply --server-side -n argocd -f "$manifest"
kubectl --context "$context" wait -n argocd \
  --for=condition=Available deployment --all --timeout=300s
kubectl --context "$context" rollout status -n argocd \
  statefulset/argocd-application-controller --timeout=300s

echo "Argo CD ${version} is running only on argocd-hub."
