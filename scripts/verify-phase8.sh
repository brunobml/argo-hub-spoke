#!/usr/bin/env bash
set -euo pipefail

hub_context=k3d-argocd-hub

for spoke in spoke-01 spoke-02; do
  context="k3d-${spoke}"
  app="demo-app-${spoke}"
  echo "[$spoke]"

  sync=$(kubectl --context "$hub_context" -n argocd get application "$app" \
    -o jsonpath='{.status.sync.status}')
  health=$(kubectl --context "$hub_context" -n argocd get application "$app" \
    -o jsonpath='{.status.health.status}')
  echo "Application: sync=$sync health=$health"
  [[ "$sync" == Synced && "$health" == Healthy ]] || exit 1

  store_ready=$(kubectl --context "$context" -n demo get secretstore \
    moto-secrets-manager \
    -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}')
  external_ready=$(kubectl --context "$context" -n demo get externalsecret \
    demo-database \
    -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}')
  echo "SecretStore: $store_ready; ExternalSecret: $external_ready"
  [[ "$store_ready" == True && "$external_ready" == True ]] || exit 1

  # Print only key names, never values.
  kubectl --context "$context" -n demo get secret demo-database \
    -o go-template='Secret {{.metadata.name}} keys:{{range $key, $_ := .data}} {{$key}}{{end}}{{"\n"}}'

  response=$(kubectl --context "$context" get --raw \
    /api/v1/namespaces/demo/services/http:demo-app:80/proxy/)
  echo "$response"
  grep -Fq "Cluster: $spoke" <<< "$response"
  grep -Fq 'Secret loaded: yes' <<< "$response"
  echo
done
