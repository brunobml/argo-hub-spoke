#!/usr/bin/env bash
set -euo pipefail

hub_context=k3d-argocd-hub

kubectl --context "$hub_context" -n argocd get applicationset demo-app

echo
echo "Generated Applications:"
kubectl --context "$hub_context" -n argocd get applications \
  demo-app-spoke-01 demo-app-spoke-02 \
  -o custom-columns='NAME:.metadata.name,OWNER:.metadata.ownerReferences[0].kind,SYNC:.status.sync.status,HEALTH:.status.health.status,DESTINATION:.spec.destination.server'

for spoke in spoke-01 spoke-02; do
  app="demo-app-${spoke}"
  sync=$(kubectl --context "$hub_context" -n argocd get application "$app" \
    -o jsonpath='{.status.sync.status}')
  health=$(kubectl --context "$hub_context" -n argocd get application "$app" \
    -o jsonpath='{.status.health.status}')
  owner=$(kubectl --context "$hub_context" -n argocd get application "$app" \
    -o jsonpath='{.metadata.ownerReferences[0].kind}')
  [[ "$sync" == Synced && "$health" == Healthy && "$owner" == ApplicationSet ]] || {
    echo "$app failed ownership, sync, or health verification" >&2
    exit 1
  }

  echo
  echo "[$spoke response]"
  response=$(kubectl --context "k3d-${spoke}" get --raw \
    /api/v1/namespaces/demo/services/http:demo-app:80/proxy/)
  echo "$response"
  grep -Fq "Cluster: $spoke" <<< "$response"
done
