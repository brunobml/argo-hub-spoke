#!/usr/bin/env bash
set -euo pipefail

echo "Moto container:"
docker ps --filter name='^/moto$' \
  --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}'

network=$(docker inspect moto \
  --format '{{range $name, $_ := .NetworkSettings.Networks}}{{$name}}{{end}}')
[[ "$network" == argo-lab ]] || {
  echo "Moto is attached to '$network', expected 'argo-lab'" >&2
  exit 1
}

echo
echo "Secrets Manager metadata (the value is not requested):"
docker run --rm --network argo-lab \
  -e AWS_ACCESS_KEY_ID=moto \
  -e AWS_SECRET_ACCESS_KEY=moto \
  -e AWS_DEFAULT_REGION=us-east-1 \
  amazon/aws-cli:2.31.18 \
  --endpoint-url http://moto:5000 secretsmanager describe-secret \
  --secret-id /demo/database \
  --query '{Name:Name,ARN:ARN,CreatedDate:CreatedDate}'

echo
for spoke in spoke-01 spoke-02; do
  context="k3d-${spoke}"
  pod=moto-connectivity-check
  kubectl --context "$context" delete pod "$pod" --ignore-not-found \
    --wait=false >/dev/null
  echo -n "$spoke -> Moto: "
  kubectl --context "$context" run "$pod" \
    --image=curlimages/curl:8.16.0 \
    --restart=Never \
    --rm -i \
    --command -- curl --fail --silent --max-time 10 http://moto:5000/ \
    >/dev/null
  echo "reachable"
done
