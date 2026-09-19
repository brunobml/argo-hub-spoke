#!/usr/bin/env bash
set -euo pipefail

hub_context=k3d-argocd-hub
temporary_kubeconfig=$(mktemp)
trap 'rm -f "$temporary_kubeconfig"' EXIT

k3d kubeconfig get argocd-hub > "$temporary_kubeconfig"
kubectl --kubeconfig "$temporary_kubeconfig" config set-context "$hub_context" \
  --namespace argocd >/dev/null

echo "Argo CD cluster inventory:"
KUBECONFIG="$temporary_kubeconfig" argocd cluster list --core

echo
echo "Non-sensitive hub Secret metadata:"
kubectl --context "$hub_context" -n argocd get secrets \
  -l argocd.argoproj.io/secret-type=cluster \
  -o custom-columns='SECRET:.metadata.name,ENVIRONMENT:.metadata.labels.environment,WORKLOAD:.metadata.labels.workload'

echo
echo "Effective service-account authorization (expected: yes, then no):"
for spoke in spoke-01 spoke-02; do
  context="k3d-${spoke}"
  echo "$spoke"
  allowed=$(kubectl --context "$context" auth can-i create deployments -n demo \
    --as=system:serviceaccount:kube-system:argocd-manager)
  denied=$(kubectl --context "$context" auth can-i create deployments -n default \
    --as=system:serviceaccount:kube-system:argocd-manager || true)
  printf '  create deployments in demo:    '
  echo "$allowed"
  printf '  create deployments in default: '
  echo "$denied"
  [[ "$allowed" == yes && "$denied" == no ]] || {
    echo "unexpected authorization result for $spoke" >&2
    exit 1
  }
done
