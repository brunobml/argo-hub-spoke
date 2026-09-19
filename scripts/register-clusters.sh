#!/usr/bin/env bash
set -euo pipefail

hub_context=k3d-argocd-hub
if (( $# )); then
  spokes=("$@")
else
  spokes=(spoke-01 spoke-02)
fi
for spoke in "${spokes[@]}"; do
  context="k3d-${spoke}"
  kubectl --context "$context" create namespace demo --dry-run=client -o yaml | \
    kubectl --context "$context" apply -f -

  # Remove only artifacts left by an interrupted CLI registration. The lab
  # uses the namespace Role below instead of a cluster-wide binding.
  kubectl --context "$context" delete clusterrolebinding argocd-manager-role-binding \
    --ignore-not-found >/dev/null
  kubectl --context "$context" delete clusterrole argocd-manager-role \
    --ignore-not-found >/dev/null
  kubectl --context "$context" -n demo delete rolebinding argocd-manager-role-binding \
    --ignore-not-found >/dev/null
  kubectl --context "$context" -n demo delete role argocd-manager-role \
    --ignore-not-found >/dev/null

  # Equivalent to the remote identity and namespaced access created by
  # `argocd cluster add --namespace demo`.
  kubectl --context "$context" apply -f - <<'YAML'
apiVersion: v1
kind: ServiceAccount
metadata:
  name: argocd-manager
  namespace: kube-system
---
apiVersion: v1
kind: Secret
metadata:
  name: argocd-manager-token
  namespace: kube-system
  annotations:
    kubernetes.io/service-account.name: argocd-manager
type: kubernetes.io/service-account-token
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: argocd-manager-bootstrap
  namespace: demo
rules:
  - apiGroups: ["*"]
    resources: ["*"]
    verbs: ["*"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: argocd-manager-bootstrap
  namespace: demo
subjects:
  - kind: ServiceAccount
    name: argocd-manager
    namespace: kube-system
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: argocd-manager-bootstrap
YAML

  token=""
  ca_data=""
  for _ in $(seq 1 30); do
    token=$(kubectl --context "$context" -n kube-system get secret \
      argocd-manager-token -o jsonpath='{.data.token}' 2>/dev/null || true)
    ca_data=$(kubectl --context "$context" -n kube-system get secret \
      argocd-manager-token -o jsonpath='{.data.ca\.crt}' 2>/dev/null || true)
    [[ -n "$token" && -n "$ca_data" ]] && break
    sleep 1
  done
  [[ -n "$token" && -n "$ca_data" ]] || {
    echo "service-account token for $spoke was not populated" >&2
    exit 1
  }
  token=$(printf '%s' "$token" | base64 -d)
  server="https://k3d-${spoke}-server-0:6443"
  printf -v cluster_config \
    '{"bearerToken":"%s","tlsClientConfig":{"insecure":false,"caData":"%s"}}' \
    "$token" "$ca_data"

  # This labeled Secret is Argo CD's declarative cluster registration model.
  kubectl --context "$hub_context" -n argocd create secret generic "cluster-${spoke}" \
    --from-literal=name="$spoke" \
    --from-literal=server="$server" \
    --from-literal=namespaces=demo \
    --from-literal=config="$cluster_config" \
    --dry-run=client -o yaml | \
    kubectl --context "$hub_context" label --local -f - -o yaml \
      argocd.argoproj.io/secret-type=cluster \
      environment=dev \
      workload=applications | \
    kubectl --context "$hub_context" apply -f - >/dev/null

  unset token cluster_config ca_data
  echo "Registered $spoke at $server (namespace: demo)"
done
