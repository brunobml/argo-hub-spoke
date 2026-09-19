#!/usr/bin/env bash
set -euo pipefail

: "${DEMO_DB_USERNAME:?Set DEMO_DB_USERNAME in your shell}"
: "${DEMO_DB_PASSWORD:?Set DEMO_DB_PASSWORD in your shell}"

network=argo-lab
image=${MOTO_IMAGE:-motoserver/moto:5.1.17}
docker network inspect "$network" >/dev/null

if docker container inspect moto >/dev/null 2>&1; then
  docker start moto >/dev/null 2>&1 || true
else
  docker run -d --name moto --network "$network" -p 5000:5000 "$image" >/dev/null
fi

for _ in $(seq 1 30); do
  if curl --fail --silent http://localhost:5000/ >/dev/null; then break; fi
  sleep 1
done
curl --fail --silent http://localhost:5000/ >/dev/null

secret_json=$(printf '{"username":"%s","password":"%s"}' \
  "$DEMO_DB_USERNAME" "$DEMO_DB_PASSWORD")

docker run --rm --network "$network" \
  -e AWS_ACCESS_KEY_ID=moto -e AWS_SECRET_ACCESS_KEY=moto \
  -e AWS_DEFAULT_REGION=us-east-1 \
  amazon/aws-cli:2.31.18 \
  --endpoint-url http://moto:5000 secretsmanager create-secret \
  --name /demo/database --secret-string "$secret_json" >/dev/null 2>&1 || \
docker run --rm --network "$network" \
  -e AWS_ACCESS_KEY_ID=moto -e AWS_SECRET_ACCESS_KEY=moto \
  -e AWS_DEFAULT_REGION=us-east-1 \
  amazon/aws-cli:2.31.18 \
  --endpoint-url http://moto:5000 secretsmanager put-secret-value \
  --secret-id /demo/database --secret-string "$secret_json" >/dev/null

unset secret_json
echo "Moto is ready at http://localhost:5000; /demo/database was created or updated."
