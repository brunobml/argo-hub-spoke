#!/usr/bin/env bash
set -euo pipefail

hub_context=k3d-argocd-hub

if rg -q 'spoke-03' \
  bootstrap/hub/applicationset.yaml \
  bootstrap/hub/applicationset-external-secrets.yaml; then
  echo "spoke-03 must not be hardcoded in an ApplicationSet" >&2
  exit 1
fi
echo "ApplicationSet definitions contain no spoke-03 reference."

kubectl --context k3d-spoke-03 get nodes
kubectl --context "$hub_context" -n argocd get secret cluster-spoke-03 \
  -o custom-columns='SECRET:.metadata.name,ENVIRONMENT:.metadata.labels.environment,WORKLOAD:.metadata.labels.workload'

echo
echo "Generated Applications:"
kubectl --context "$hub_context" -n argocd get applications \
  demo-app-spoke-01 demo-app-spoke-02 demo-app-spoke-03 \
  -o custom-columns='NAME:.metadata.name,OWNER:.metadata.ownerReferences[0].kind,SYNC:.status.sync.status,HEALTH:.status.health.status'

for spoke in spoke-01 spoke-02 spoke-03; do
  app="demo-app-${spoke}"
  sync=$(kubectl --context "$hub_context" -n argocd get application "$app" \
    -o jsonpath='{.status.sync.status}')
  health=$(kubectl --context "$hub_context" -n argocd get application "$app" \
    -o jsonpath='{.status.health.status}')
  owner=$(kubectl --context "$hub_context" -n argocd get application "$app" \
    -o jsonpath='{.metadata.ownerReferences[0].kind}')
  [[ "$sync" == Synced && "$health" == Healthy && "$owner" == ApplicationSet ]] || exit 1
done

echo
echo "[spoke-03 platform and application]"
kubectl --context k3d-spoke-03 -n external-secrets get deployment
kubectl --context k3d-spoke-03 -n demo get secretstore,externalsecret
kubectl --context k3d-spoke-03 -n demo get secret demo-database \
  -o go-template='Secret {{.metadata.name}} keys:{{range $key, $_ := .data}} {{$key}}{{end}}{{"\n"}}'

response=$(kubectl --context k3d-spoke-03 get --raw \
  /api/v1/namespaces/demo/services/http:demo-app:80/proxy/)
echo "$response"
grep -Fq 'Cluster: spoke-03' <<< "$response"
grep -Fq 'Secret loaded: yes' <<< "$response"

subject=system:serviceaccount:kube-system:argocd-manager
secret_update=$(kubectl --context k3d-spoke-03 auth can-i update secrets \
  -n demo --as="$subject" || true)
[[ "$secret_update" == no ]] || {
  echo "spoke-03 Argo CD identity can unexpectedly update Secrets" >&2
  exit 1
}
echo "Argo CD Secret mutation on spoke-03: denied (expected)"
