#!/usr/bin/env bash
set -euo pipefail

chart_version=${ESO_CHART_VERSION:-1.3.0}
spokes=("${@:-spoke-01 spoke-02}")

helm repo add external-secrets https://charts.external-secrets.io --force-update
helm repo update external-secrets

for spoke_list in "${spokes[@]}"; do
  for spoke in $spoke_list; do
    context="k3d-${spoke}"
    helm upgrade --install external-secrets external-secrets/external-secrets \
      --kube-context "$context" \
      --namespace external-secrets \
      --create-namespace \
      --version "$chart_version" \
      --set 'extraEnv[0].name=AWS_SECRETSMANAGER_ENDPOINT' \
      --set-string 'extraEnv[0].value=http://moto:5000' \
      --wait --timeout 5m

    kubectl --context "$context" -n demo create secret generic aws-credentials \
      --from-literal=access-key=moto \
      --from-literal=secret-access-key=moto \
      --dry-run=client -o yaml | kubectl --context "$context" apply -f -
  done
done
