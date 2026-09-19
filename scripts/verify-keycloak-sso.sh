#!/usr/bin/env bash
set -euo pipefail

context=k3d-argocd-hub
issuer=http://keycloak.localhost/realms/argocd-lab

kubectl --context "$context" -n keycloak get deployment,pod,service
kubectl --context "$context" get --raw \
  /api/v1/namespaces/keycloak/services/http:keycloak:80/proxy/realms/argocd-lab/.well-known/openid-configuration | \
  grep -Fq "\"issuer\":\"${issuer}\""
kubectl --context "$context" -n argocd get configmap argocd-cm \
  -o jsonpath='{.data.oidc\.config}' | grep -Fq "$issuer"
kubectl --context "$context" -n argocd get configmap argocd-rbac-cm \
  -o jsonpath='{.data.policy\.csv}' | grep -Fq 'argocd-admins'
curl --fail --silent http://keycloak.localhost/realms/argocd-lab/.well-known/openid-configuration \
  | grep -Fq "\"issuer\":\"${issuer}\""
curl --fail --silent --output /dev/null http://argocd.localhost/healthz

echo "Keycloak discovery, Argo CD OIDC, and group RBAC configuration are valid."
