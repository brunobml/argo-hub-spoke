#!/usr/bin/env bash
set -euo pipefail

context=k3d-argocd-hub
namespace=keycloak
runtime_secret=keycloak-runtime
realm_template=platform/keycloak/realm-template.json
rendered_realm=$(mktemp)
trap 'rm -f "$rendered_realm"' EXIT

if ! docker port k3d-argocd-hub-serverlb 80/tcp 2>/dev/null | grep -q .; then
  k3d cluster edit argocd-hub --port-add '127.0.0.1:80:80@loadbalancer'
fi
if ! docker port k3d-argocd-hub-serverlb 443/tcp 2>/dev/null | grep -q .; then
  k3d cluster edit argocd-hub --port-add '127.0.0.1:443:443@loadbalancer'
fi

generate_secret() {
  openssl rand -hex 24
}

kubectl --context "$context" apply -f platform/keycloak/namespace.yaml

if ! kubectl --context "$context" -n "$namespace" get secret "$runtime_secret" \
  >/dev/null 2>&1; then
  admin_password=${KEYCLOAK_ADMIN_PASSWORD:-$(generate_secret)}
  developer_password=${KEYCLOAK_DEVELOPER_PASSWORD:-$(generate_secret)}
  viewer_password=${KEYCLOAK_VIEWER_PASSWORD:-$(generate_secret)}
  client_secret=${ARGOCD_OIDC_CLIENT_SECRET:-$(generate_secret)}

  kubectl --context "$context" -n "$namespace" create secret generic "$runtime_secret" \
    --from-literal=admin-password="$admin_password" \
    --from-literal=developer-password="$developer_password" \
    --from-literal=viewer-password="$viewer_password" \
    --from-literal=argocd-client-secret="$client_secret" >/dev/null
else
  admin_password=$(kubectl --context "$context" -n "$namespace" get secret "$runtime_secret" \
    -o jsonpath='{.data.admin-password}' | base64 -d)
  developer_password=$(kubectl --context "$context" -n "$namespace" get secret "$runtime_secret" \
    -o jsonpath='{.data.developer-password}' | base64 -d)
  viewer_password=$(kubectl --context "$context" -n "$namespace" get secret "$runtime_secret" \
    -o jsonpath='{.data.viewer-password}' | base64 -d)
  client_secret=$(kubectl --context "$context" -n "$namespace" get secret "$runtime_secret" \
    -o jsonpath='{.data.argocd-client-secret}' | base64 -d)
fi

sed \
  -e "s/REPLACE_DEVELOPER_PASSWORD/${developer_password}/g" \
  -e "s/REPLACE_VIEWER_PASSWORD/${viewer_password}/g" \
  -e "s/REPLACE_ARGOCD_CLIENT_SECRET/${client_secret}/g" \
  "$realm_template" > "$rendered_realm"

kubectl --context "$context" -n "$namespace" create secret generic keycloak-realm-import \
  --from-file=argocd-lab-realm.json="$rendered_realm" \
  --dry-run=client -o yaml | kubectl --context "$context" apply -f - >/dev/null
kubectl --context "$context" apply -k platform/keycloak
kubectl --context "$context" apply -f bootstrap/hub/argocd-ingress.yaml

kubectl --context "$context" apply -f bootstrap/hub/coredns-keycloak.yaml
kubectl --context "$context" -n kube-system rollout restart deployment/coredns
kubectl --context "$context" -n kube-system rollout status deployment/coredns --timeout=180s

kubectl --context "$context" -n argocd patch secret argocd-secret --type merge \
  -p "{\"stringData\":{\"oidc.keycloak.clientSecret\":\"${client_secret}\"}}" >/dev/null
kubectl --context "$context" -n argocd patch configmap argocd-cm --type merge \
  --patch-file bootstrap/hub/argocd-cm-sso-patch.yaml
kubectl --context "$context" -n argocd patch configmap argocd-rbac-cm --type merge \
  --patch-file bootstrap/hub/argocd-rbac-sso-patch.yaml
kubectl --context "$context" -n argocd patch configmap argocd-cmd-params-cm --type merge \
  --patch-file bootstrap/hub/argocd-insecure-patch.yaml

kubectl --context "$context" -n "$namespace" rollout restart deployment/keycloak
kubectl --context "$context" -n "$namespace" rollout status deployment/keycloak \
  --timeout=600s
kubectl --context "$context" -n argocd rollout restart deployment/argocd-server
kubectl --context "$context" -n argocd rollout status deployment/argocd-server \
  --timeout=300s

unset admin_password developer_password viewer_password client_secret
echo "Keycloak SSO is installed. See docs/keycloak-sso.md for access and verification."
