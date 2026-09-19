#!/usr/bin/env bash
set -euo pipefail

phase=${1:-}
: "${REPO_URL:?Set REPO_URL to the pushed Git repository URL}"
revision=${TARGET_REVISION:-HEAD}
hub_context=k3d-argocd-hub

case "$phase" in
  manual)
    manifest=bootstrap/hub/manual-application.yaml
    kubectl --context "$hub_context" -n argocd delete applicationset demo-app --ignore-not-found
    ;;
  applicationset)
    manifest=bootstrap/hub/applicationset.yaml
    kubectl --context "$hub_context" -n argocd delete application demo-app-spoke-01 --ignore-not-found
    ;;
  external-secrets)
    manifest=bootstrap/hub/applicationset-external-secrets.yaml
    ;;
  *)
    echo "usage: REPO_URL=<url> $0 {manual|applicationset|external-secrets}" >&2
    exit 2
    ;;
esac

sed -e "s|REPLACE_REPO_URL|${REPO_URL}|g" -e "s|REPLACE_REVISION|${revision}|g" \
  bootstrap/hub/project.yaml | kubectl --context "$hub_context" apply -f -
sed -e "s|REPLACE_REPO_URL|${REPO_URL}|g" -e "s|REPLACE_REVISION|${revision}|g" \
  "$manifest" | kubectl --context "$hub_context" apply -f -
