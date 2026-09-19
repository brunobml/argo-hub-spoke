#!/usr/bin/env bash
set -euo pipefail

spokes=("${@:-spoke-01 spoke-02}")
for spoke_list in "${spokes[@]}"; do
  for spoke in $spoke_list; do
    context="k3d-${spoke}"
    sed "s/REPLACE_SPOKE/${spoke}/g" bootstrap/spoke/argocd-rbac.yaml | \
      kubectl --context "$context" apply -f -
    kubectl --context "$context" -n demo delete rolebinding argocd-manager-bootstrap \
      --ignore-not-found
    kubectl --context "$context" -n demo delete role argocd-manager-bootstrap \
      --ignore-not-found
    kubectl --context "$context" delete clusterrolebinding argocd-manager-role-binding \
      --ignore-not-found
    kubectl --context "$context" delete clusterrole argocd-manager-role --ignore-not-found
    echo "$spoke now grants Argo CD access only in namespace demo"
  done
done
