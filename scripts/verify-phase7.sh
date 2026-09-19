#!/usr/bin/env bash
set -euo pipefail

for spoke in spoke-01 spoke-02; do
  context="k3d-${spoke}"
  echo "[$spoke]"
  helm --kube-context "$context" -n external-secrets list
  kubectl --context "$context" -n external-secrets get deployment,pod

  endpoint=$(kubectl --context "$context" -n external-secrets get deployment \
    external-secrets \
    -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="AWS_SECRETSMANAGER_ENDPOINT")].value}')
  [[ "$endpoint" == http://moto:5000 ]] || {
    echo "unexpected Secrets Manager endpoint on $spoke: $endpoint" >&2
    exit 1
  }
  echo "AWS_SECRETSMANAGER_ENDPOINT=$endpoint"

  kubectl --context "$context" get crd \
    externalsecrets.external-secrets.io \
    secretstores.external-secrets.io
  kubectl --context "$context" -n demo get secret aws-credentials \
    -o custom-columns='NAME:.metadata.name,TYPE:.type' --no-headers

  resources=$(kubectl --context "$context" -n demo get \
    secretstore,externalsecret --ignore-not-found -o name)
  [[ -z "$resources" ]] || {
    echo "Phase 8 resources already exist on $spoke: $resources" >&2
    exit 1
  }
  echo "No SecretStore or ExternalSecret yet (expected in Phase 7)"
  echo
done
