#!/usr/bin/env bash
set -euo pipefail

hub_context=k3d-argocd-hub
app=demo-app-spoke-01

kubectl --context "$hub_context" -n argocd get application "$app" \
  -o custom-columns='NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status,REVISION:.status.sync.revision'

sync=$(kubectl --context "$hub_context" -n argocd get application "$app" \
  -o jsonpath='{.status.sync.status}')
health=$(kubectl --context "$hub_context" -n argocd get application "$app" \
  -o jsonpath='{.status.health.status}')
[[ "$sync" == Synced && "$health" == Healthy ]] || {
  echo "$app is not Synced and Healthy" >&2
  exit 1
}

kubectl --context k3d-spoke-01 -n demo get deployment,pod,service
echo
echo "Application response through the Kubernetes API proxy:"
kubectl --context k3d-spoke-01 get --raw \
  /api/v1/namespaces/demo/services/http:demo-app:80/proxy/
echo

if kubectl --context k3d-spoke-02 -n demo get deployment demo-app >/dev/null 2>&1; then
  echo "unexpected: demo-app exists on spoke-02 during Phase 4" >&2
  exit 1
fi
echo "spoke-02: demo-app absent (expected during Phase 4)"
