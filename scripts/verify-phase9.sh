#!/usr/bin/env bash
set -euo pipefail

hub_context=k3d-argocd-hub
subject=system:serviceaccount:kube-system:argocd-manager

can() {
  local context=$1 expected=$2 verb=$3 resource=$4 namespace=${5:-}
  local result
  if [[ -n "$namespace" ]]; then
    result=$(kubectl --context "$context" auth can-i "$verb" "$resource" \
      -n "$namespace" --as="$subject" || true)
  else
    result=$(kubectl --context "$context" auth can-i "$verb" "$resource" \
      --as="$subject" || true)
  fi
  printf '  %-46s %s\n' "$verb $resource ${namespace:+in $namespace}" "$result"
  [[ "$result" == "$expected" ]]
}

for spoke in spoke-01 spoke-02; do
  context="k3d-${spoke}"
  echo "[$spoke permission matrix]"
  can "$context" yes create deployments.apps demo
  can "$context" yes create services demo
  can "$context" yes create externalsecrets.external-secrets.io demo
  can "$context" no update secrets demo
  can "$context" no create jobs.batch demo
  can "$context" no create namespaces
  echo
done

./scripts/verify-phase8.sh

echo "[self-heal demonstration on spoke-01]"
restore_replica() {
  kubectl --context k3d-spoke-01 -n demo scale deployment demo-app \
    --replicas=1 >/dev/null 2>&1 || true
}
trap restore_replica EXIT

kubectl --context k3d-spoke-01 -n demo scale deployment demo-app --replicas=5
for _ in $(seq 1 60); do
  replicas=$(kubectl --context k3d-spoke-01 -n demo get deployment demo-app \
    -o jsonpath='{.spec.replicas}')
  sync=$(kubectl --context "$hub_context" -n argocd get application \
    demo-app-spoke-01 -o jsonpath='{.status.sync.status}')
  echo "replicas=$replicas sync=$sync"
  if [[ "$replicas" == 1 && "$sync" == Synced ]]; then
    trap - EXIT
    echo "Argo CD restored the Git-defined replica count."
    exit 0
  fi
  sleep 3
done

echo "Argo CD did not self-heal within the expected time" >&2
exit 1
