# Manual learning path

This tutorial reaches the same final architecture as the scripted path in the
[README](../README.md), but exposes the important operations one at a time.
Use it when the objective is understanding rather than rebuilding the lab as
quickly as possible.

The scripts remain the executable reference. Before running a manual phase,
read the corresponding script and predict what it will change:

```bash
sed -n '1,260p' scripts/<script-name>.sh
```

Do not mix the quick and manual paths within the same phase. Most commands are
idempotent, but switching paths midway makes it harder to understand which
command created an object. The commands below assume a clean lab and a shell in
the repository root.

If your completed lab is still running, you can read the tutorial without
changing it, or deliberately rebuild from Phase 1. `./scripts/cleanup.sh`
deletes the lab clusters and Moto container, so use it only when you intend to
discard the current local environment.

For every phase, use this learning loop:

```text
inspect -> predict -> apply one change -> observe -> explain -> verify
```

## Phase 1 — Create and inspect three clusters

### Objective

Create one management cluster and two workload clusters on a shared Docker
network. The fixed host API ports are for workstation access; containers use
their Docker DNS names and port `6443`.

### Build it manually

```bash
docker network create argo-lab

k3d cluster create argocd-hub \
  --network argo-lab \
  --api-port 127.0.0.1:6550 \
  --port '127.0.0.1:80:80@loadbalancer' \
  --port '127.0.0.1:443:443@loadbalancer' \
  --servers 1 --agents 0 --wait

k3d cluster create spoke-01 \
  --network argo-lab --api-port 127.0.0.1:6551 \
  --servers 1 --agents 0 --wait

k3d cluster create spoke-02 \
  --network argo-lab --api-port 127.0.0.1:6552 \
  --servers 1 --agents 0 --wait
```

### Observe and verify

```bash
k3d cluster list
kubectl config get-contexts
kubectl --context k3d-argocd-hub get nodes
kubectl --context k3d-spoke-01 get nodes
kubectl --context k3d-spoke-02 get nodes
docker network inspect argo-lab
```

`kubectl config get-contexts` may also show contexts from unrelated local
labs. The three contexts created here are `k3d-argocd-hub`,
`k3d-spoke-01`, and `k3d-spoke-02`; later commands always select one
explicitly.

Notice that the kubeconfig endpoints use `127.0.0.1:6550-6552`, while Docker
containers on `argo-lab` can resolve names such as
`k3d-spoke-01-server-0:6443`.

Production mapping: the Docker network represents routable VPC connectivity,
and the three k3d clusters represent one management EKS cluster and two
workload EKS clusters.

## Phase 2 — Install Argo CD only on the hub

### Objective

Create a single GitOps control plane. No Argo CD controller is installed on a
spoke.

### Build it manually

```bash
export ARGO_CD_VERSION=v3.1.8

kubectl --context k3d-argocd-hub create namespace argocd
kubectl --context k3d-argocd-hub apply --server-side -n argocd \
  -f "https://raw.githubusercontent.com/argoproj/argo-cd/${ARGO_CD_VERSION}/manifests/install.yaml"

kubectl --context k3d-argocd-hub wait -n argocd \
  --for=condition=Available deployment --all --timeout=300s
kubectl --context k3d-argocd-hub rollout status -n argocd \
  statefulset/argocd-application-controller --timeout=300s
```

### Observe and verify

```bash
kubectl --context k3d-argocd-hub -n argocd get deploy,statefulset,pods
kubectl --context k3d-argocd-hub get crd \
  applications.argoproj.io applicationsets.argoproj.io appprojects.argoproj.io

kubectl --context k3d-spoke-01 get namespace argocd
kubectl --context k3d-spoke-02 get namespace argocd
```

The last two commands should return `NotFound` with a non-zero exit status.
That result is expected when commands are entered interactively; do not place
those negative checks unguarded in a script using `set -e`. Identify the
server, repository server, application controller, and ApplicationSet
controller in the hub output before continuing.

## Phase 3 — Register one spoke by hand

### Objective

Understand both halves of remote cluster registration:

```text
spoke identity and RBAC -> bearer token and CA -> hub cluster Secret
```

The commands below register `spoke-01`. After inspecting it, either repeat them
with `spoke-02` or let `./scripts/register-clusters.sh spoke-02` perform the
same operations.

### 1. Create the remote identity

```bash
export SPOKE=spoke-01
export SPOKE_CONTEXT=k3d-${SPOKE}
export HUB_CONTEXT=k3d-argocd-hub

# Argo CD core mode reads its namespace from the selected kube-context.
kubectl config set-context "$HUB_CONTEXT" --namespace=argocd

kubectl --context "$SPOKE_CONTEXT" create namespace demo

kubectl --context "$SPOKE_CONTEXT" apply -f - <<'YAML'
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
```

The broad Role is temporary and only namespaced. Phase 9 replaces it with an
explicit mutation allowlist.

### 2. Read the credential without displaying it

```bash
token_data=$(kubectl --context "$SPOKE_CONTEXT" -n kube-system get secret \
  argocd-manager-token -o jsonpath='{.data.token}')
ca_data=$(kubectl --context "$SPOKE_CONTEXT" -n kube-system get secret \
  argocd-manager-token -o jsonpath='{.data.ca\.crt}')
token=$(printf '%s' "$token_data" | base64 -d)

printf 'token bytes=%s; CA bytes=%s\n' "${#token}" "${#ca_data}"
```

Do not echo `token`, `token_data`, or `ca_data`. Kubernetes Secret encoding is
not encryption.

### 3. Create the hub-side cluster Secret

```bash
server=https://k3d-${SPOKE}-server-0:6443
printf -v cluster_config \
  '{"bearerToken":"%s","tlsClientConfig":{"insecure":false,"caData":"%s"}}' \
  "$token" "$ca_data"

kubectl --context "$HUB_CONTEXT" -n argocd create secret generic \
  "cluster-${SPOKE}" \
  --from-literal=name="$SPOKE" \
  --from-literal=server="$server" \
  --from-literal=namespaces=demo \
  --from-literal=config="$cluster_config" \
  --dry-run=client -o yaml | \
kubectl --context "$HUB_CONTEXT" label --local -f - -o yaml \
  argocd.argoproj.io/secret-type=cluster \
  environment=dev workload=applications | \
kubectl --context "$HUB_CONTEXT" apply -f -

unset token token_data ca_data cluster_config
```

Argo CD recognizes the Secret by the `secret-type=cluster` label. The
`workload=applications` label is placement metadata used later by the Cluster
Generator.

### Observe and verify

```bash
kubectl --context "$HUB_CONTEXT" -n argocd get secret "cluster-${SPOKE}" \
  -o custom-columns='NAME:.metadata.name,TYPE:.metadata.labels.argocd\.argoproj\.io/secret-type,ENV:.metadata.labels.environment,WORKLOAD:.metadata.labels.workload'

subject=system:serviceaccount:kube-system:argocd-manager
kubectl --context "$SPOKE_CONTEXT" auth can-i create deployments.apps \
  -n demo --as="$subject"
kubectl --context "$SPOKE_CONTEXT" auth can-i create deployments.apps \
  -n default --as="$subject"

argocd cluster list --core --kube-context "$HUB_CONTEXT"
```

Expected permission answers are `yes` in `demo` and `no` in `default`.
The `set-context` command above is required because `argocd --core` otherwise
looks for `argocd-cm` in the context's default namespace. It updates only the
local kubeconfig; explicit `-n` flags still take precedence.

Now register and verify the second spoke:

```bash
./scripts/register-clusters.sh spoke-02
./scripts/verify-phase3.sh
```

## Phase 4 — Create one Application explicitly

### Objective

Understand an `Application` before generating applications dynamically. Git
must already contain and expose the repository contents to Argo CD.

### Inspect and render

```bash
sed -n '1,240p' bootstrap/hub/project.yaml
sed -n '1,240p' bootstrap/hub/manual-application.yaml
kubectl kustomize apps/demo-app/base

export REPO_URL=https://github.com/brunobml/argo-hub-spoke.git
export TARGET_REVISION=main

sed -e "s|REPLACE_REPO_URL|${REPO_URL}|g" \
    -e "s|REPLACE_REVISION|${TARGET_REVISION}|g" \
    bootstrap/hub/project.yaml > /tmp/demo-project.yaml
sed -e "s|REPLACE_REPO_URL|${REPO_URL}|g" \
    -e "s|REPLACE_REVISION|${TARGET_REVISION}|g" \
    bootstrap/hub/manual-application.yaml > /tmp/demo-application.yaml

sed -n '1,240p' /tmp/demo-project.yaml
sed -n '1,240p' /tmp/demo-application.yaml
```

Identify the source repository, Git revision, path, destination cluster,
destination namespace, Project, and sync policy before applying them.

### Apply and watch reconciliation

Argo CD reads the remote repository, never the local working tree. Confirm
that the desired branch is clean and contains no unpushed commits:

```bash
git status --short
git log --oneline '@{u}..HEAD'
```

Both commands should produce no output. If they show intended changes or
commits, commit and `git push` them before continuing.

```bash
kubectl --context k3d-argocd-hub apply -f /tmp/demo-project.yaml
kubectl --context k3d-argocd-hub apply -f /tmp/demo-application.yaml

kubectl --context k3d-argocd-hub -n argocd get application \
  demo-app-spoke-01 -w
```

Stop the watch with `Ctrl-C` after it is `Synced` and `Healthy`, then verify:

```bash
./scripts/verify-phase4.sh
```

The expected response includes `Secret loaded: no`; Moto and ESO are not
introduced until Phases 6–8.

Explain why the workload Pod exists on `spoke-01` even though the Application
object exists on the hub.

## Phase 5 — Replace the Application with a Cluster Generator

### Objective

Use registration metadata as the placement API. The ApplicationSet should
select cluster Secrets rather than list spoke names.

### Inspect selection before applying

```bash
kubectl --context k3d-argocd-hub -n argocd get secret \
  -l workload=applications \
  -o custom-columns='SECRET:.metadata.name,CLUSTER:.data.name,WORKLOAD:.metadata.labels.workload'
sed -n '1,260p' bootstrap/hub/applicationset.yaml
```

Predict the two Application names from the template and selected Secrets.

### Apply the generator

```bash
kubectl --context k3d-argocd-hub -n argocd delete application \
  demo-app-spoke-01 --ignore-not-found

sed -e "s|REPLACE_REPO_URL|${REPO_URL}|g" \
    -e "s|REPLACE_REVISION|${TARGET_REVISION}|g" \
    bootstrap/hub/applicationset.yaml > /tmp/demo-applicationset.yaml

kubectl --context k3d-argocd-hub apply -f /tmp/demo-applicationset.yaml
kubectl --context k3d-argocd-hub -n argocd get applicationset demo-app
kubectl --context k3d-argocd-hub -n argocd get applications -w
```

The watch intentionally uses one resource type. Some kubectl versions reject
`-w` when a comma-separated list of different resource types is supplied.
After both Applications are healthy, stop the watch and run:

```bash
./scripts/verify-phase5.sh
```

Inspect each Application's owner reference. This is the evidence that the
ApplicationSet controller generated it.

## Phase 6 — Start Moto and create a secret

### Objective

Separate secret values from Git. Moto replaces the AWS endpoint, but the API
and secret reference model remain representative of AWS Secrets Manager.

### Start Moto

```bash
docker run -d --name moto --network argo-lab -p 5000:5000 \
  motoserver/moto:5.1.17

curl --fail http://localhost:5000/
```

The HTTP response proves that the Moto server is reachable. The Secrets
Manager `create-secret` and `describe-secret` calls below prove that the
specific emulated AWS API is working.

### Create the secret without committing it

```bash
read -r -p 'Database username: ' DEMO_DB_USERNAME
read -r -s -p 'Database password: ' DEMO_DB_PASSWORD; echo

secret_json=$(printf '{"username":"%s","password":"%s"}' \
  "$DEMO_DB_USERNAME" "$DEMO_DB_PASSWORD")

docker run --rm --network argo-lab \
  -e AWS_ACCESS_KEY_ID=moto \
  -e AWS_SECRET_ACCESS_KEY=moto \
  -e AWS_DEFAULT_REGION=us-east-1 \
  amazon/aws-cli:2.31.18 \
  --endpoint-url http://moto:5000 secretsmanager create-secret \
  --name /demo/database --secret-string "$secret_json"

unset secret_json DEMO_DB_USERNAME DEMO_DB_PASSWORD
```

For this lab command, avoid `"` and `\` characters in the entered values. The
scripted path uses the same intentionally small JSON construction.
Passing a secret as a CLI argument is acceptable only for this disposable
local emulator; production secret population should use an approved workflow
that does not expose values through shell history or process arguments.

### Observe without exposing the value

```bash
docker run --rm --network argo-lab \
  -e AWS_ACCESS_KEY_ID=moto \
  -e AWS_SECRET_ACCESS_KEY=moto \
  -e AWS_DEFAULT_REGION=us-east-1 \
  amazon/aws-cli:2.31.18 \
  --endpoint-url http://moto:5000 secretsmanager describe-secret \
  --secret-id /demo/database

./scripts/verify-phase6.sh
```

The workstation reaches `localhost:5000`; containers and Pods must reach
`moto:5000` on the shared Docker network.

## Phase 7 — Install ESO and stop before creating an ExternalSecret

### Objective

Install the provider controller and CRDs as platform bootstrap. Install one
spoke manually, inspect it, and repeat for the second spoke.

```bash
helm repo add external-secrets https://charts.external-secrets.io
helm repo update external-secrets

helm upgrade --install external-secrets external-secrets/external-secrets \
  --kube-context k3d-spoke-01 \
  --namespace external-secrets --create-namespace \
  --version 1.3.2 \
  --set 'extraEnv[0].name=AWS_SECRETSMANAGER_ENDPOINT' \
  --set-string 'extraEnv[0].value=http://moto:5000' \
  --wait --timeout 5m

kubectl --context k3d-spoke-01 -n demo create secret generic aws-credentials \
  --from-literal=access-key=moto \
  --from-literal=secret-access-key=moto
```

The credentials are dummy Moto credentials, not application secret values.
Inspect the CRDs and controller before repeating the installation:

```bash
kubectl --context k3d-spoke-01 get crd | grep external-secrets
kubectl --context k3d-spoke-01 -n external-secrets get deploy,pods

./scripts/install-eso.sh spoke-02
./scripts/verify-phase7.sh
```

At this point ESO exists, but no `SecretStore`, `ExternalSecret`, or generated
`demo-database` Secret should exist yet.

## Phase 8 — Trace secret delivery end to end

### Objective

Let Argo CD create only the references. ESO reads the value from Moto and owns
the resulting Kubernetes Secret.

### Inspect the chain

```bash
sed -n '1,220p' platform/external-secrets/secret-store.yaml
sed -n '1,220p' platform/external-secrets/external-secret.yaml
sed -n '1,160p' apps/demo-app/overlays/with-external-secrets/kustomization.yaml
kubectl kustomize apps/demo-app/overlays/with-external-secrets
```

Trace these fields before applying anything:

```text
ExternalSecret.spec.secretStoreRef
  -> SecretStore provider
  -> /demo/database in Moto
  -> demo-database Kubernetes Secret
  -> optional volume in the demo Deployment
```

### Switch the ApplicationSet to the overlay

```bash
sed -e "s|REPLACE_REPO_URL|${REPO_URL}|g" \
    -e "s|REPLACE_REVISION|${TARGET_REVISION}|g" \
    bootstrap/hub/applicationset-external-secrets.yaml \
    > /tmp/demo-applicationset-external-secrets.yaml

kubectl --context k3d-argocd-hub apply \
  -f /tmp/demo-applicationset-external-secrets.yaml
```

Observe one spoke in dependency order:

```bash
# kubectl wait fails immediately when a named resource does not exist yet.
# First give Argo CD up to two minutes to create both objects.
for _ in $(seq 1 24); do
  if kubectl --context k3d-spoke-01 -n demo get \
      secretstore/moto-secrets-manager >/dev/null 2>&1 && \
     kubectl --context k3d-spoke-01 -n demo get \
      externalsecret/demo-database >/dev/null 2>&1; then
    break
  fi
  sleep 5
done
kubectl --context k3d-spoke-01 -n demo get \
  secretstore/moto-secrets-manager >/dev/null
kubectl --context k3d-spoke-01 -n demo get \
  externalsecret/demo-database >/dev/null

kubectl --context k3d-spoke-01 -n demo wait \
  --for=condition=Ready secretstore/moto-secrets-manager --timeout=120s
kubectl --context k3d-spoke-01 -n demo wait \
  --for=condition=Ready externalsecret/demo-database --timeout=120s

kubectl --context k3d-spoke-01 -n demo get secret demo-database \
  -o go-template='keys:{{range $key, $_ := .data}} {{$key}}{{end}}{{"\n"}}'
kubectl --context k3d-spoke-01 get --raw \
  /api/v1/namespaces/demo/services/http:demo-app:80/proxy/
```

The existence poll covers ApplicationSet and Argo CD reconciliation time. The
two `kubectl wait` calls then cover provider readiness after the objects exist.
Normal convergence can take several seconds to roughly two minutes and does
not require restarting the Argo CD application controller.

Print only key names, not values. Complete verification across both spokes:

```bash
./scripts/verify-phase8.sh
```

## Phase 9 — Replace bootstrap access with least privilege

### Objective

Make the centralized controller's blast radius visible and then reduce it.
The Argo CD identity needs broad read access in `demo` for its cache, but only
an explicit set of resource types is mutable.

### Record the bootstrap permissions

```bash
subject=system:serviceaccount:kube-system:argocd-manager

kubectl --context k3d-spoke-01 auth can-i update deployments.apps \
  -n demo --as="$subject"
kubectl --context k3d-spoke-01 auth can-i update secrets \
  -n demo --as="$subject"
kubectl --context k3d-spoke-01 auth can-i create clusterroles \
  --as="$subject"
```

Expected answers before hardening are `yes`, `yes`, and `no`.

### Apply the restricted Role to one spoke

```bash
sed 's/REPLACE_SPOKE/spoke-01/g' bootstrap/spoke/argocd-rbac.yaml \
  > /tmp/spoke-01-argocd-rbac.yaml
kubectl --context k3d-spoke-01 apply -f /tmp/spoke-01-argocd-rbac.yaml

kubectl --context k3d-spoke-01 -n demo delete rolebinding \
  argocd-manager-bootstrap
kubectl --context k3d-spoke-01 -n demo delete role \
  argocd-manager-bootstrap
```

Repeat the permission checks. Deployment mutation should remain `yes`, while
Secret mutation and cluster-wide administration should be `no`.

Finish and verify both spokes:

```bash
./scripts/harden-rbac.sh spoke-02
./scripts/verify-phase9.sh
```

The verifier also creates temporary Deployment drift and watches Argo CD
restore the Git-defined replica count.

## Phase 10 — Add a cluster in observable stages

### Objective

Prove that the label, not a hardcoded spoke list, controls placement. This is
the manual decomposition of `scripts/create-spoke.sh`.

### 1. Create the cluster

```bash
k3d cluster create spoke-03 \
  --network argo-lab --api-port 127.0.0.1:6553 \
  --servers 1 --agents 0 --wait
kubectl --context k3d-spoke-03 create namespace demo
```

Confirm that no Application exists yet:

```bash
kubectl --context k3d-argocd-hub -n argocd get application \
  demo-app-spoke-03
```

`NotFound` is expected.

### 2. Install platform prerequisites

```bash
./scripts/install-eso.sh spoke-03
```

ESO is installed before exposing the cluster to ApplicationSet so the first
application sync does not race CRD installation.

### 3. Register without the placement label

Repeat the Phase 3 registration commands beginning with **Create the remote
identity** (the `demo` namespace already exists), using:

```bash
export SPOKE=spoke-03
export SPOKE_CONTEXT=k3d-spoke-03
```

When labeling the hub cluster Secret, initially omit
`workload=applications`. Apply only these labels:

```text
argocd.argoproj.io/secret-type=cluster
environment=dev
```

Then verify that Argo CD knows the cluster but ApplicationSet has still not
generated `demo-app-spoke-03`:

```bash
argocd cluster list --core --kube-context k3d-argocd-hub
kubectl --context k3d-argocd-hub -n argocd get application \
  demo-app-spoke-03
```

### 4. Harden access before placement

```bash
./scripts/harden-rbac.sh spoke-03
```

### 5. Add the placement label and watch discovery

```bash
kubectl --context k3d-argocd-hub -n argocd label secret \
  cluster-spoke-03 workload=applications

kubectl --context k3d-argocd-hub -n argocd get application \
  demo-app-spoke-03 -w
```

Stop the watch after the Application becomes `Synced` and `Healthy`, then run:

```bash
./scripts/verify-phase10.sh
```

No ApplicationSet or application manifest was edited. Registration metadata
caused the existing Cluster Generator to create the new Application.

## Suggested failure exercises

After the successful path, perform one failure at a time and predict the
observable symptom before running it:

1. Scale `demo-app` manually and watch self-healing restore one replica.
2. Stop Moto and inspect the ExternalSecret condition.
3. Stop one spoke and compare all cluster/Application health on the hub.
4. Remove the placement label from `spoke-03` and observe the generator. Read
   the ApplicationSet deletion behavior before doing this because generated
   Applications have owner references.

The commands are listed in the [README](../README.md#drift-and-failure-exercises).

## When to use the scripts again

Use the manual path once to learn the object relationships. Use scripts for:

- rebuilding after cleanup;
- repeating an already-understood phase;
- demonstrations where setup time matters;
- comparing an automated result with the objects you created manually.

The scripts are not a second architecture. They automate the exact operations
shown here.

## Optional extension — Inspect Keycloak SSO progressively

Keycloak is intentionally outside the ten core delivery phases. First read
[the SSO architecture and access guide](keycloak-sso.md), then inspect the
inputs in dependency order:

```bash
sed -n '1,240p' platform/keycloak/realm-template.json
sed -n '1,180p' platform/keycloak/deployment.yaml
sed -n '1,140p' platform/keycloak/ingress.yaml
sed -n '1,180p' bootstrap/hub/argocd-cm-sso-patch.yaml
sed -n '1,180p' bootstrap/hub/argocd-rbac-sso-patch.yaml
sed -n '1,340p' scripts/install-keycloak-sso.sh
```

Identify these relationships before running the installer:

```text
Keycloak user -> Keycloak group -> groups token claim -> Argo CD RBAC role
Argo CD        -> OIDC client secret -> Keycloak client
browser        -> *.localhost Ingress -> Traefik -> Argo CD or Keycloak
```

Then install and observe each boundary:

```bash
./scripts/install-keycloak-sso.sh

kubectl --context k3d-argocd-hub -n keycloak get deploy,pod,service,ingress
kubectl --context k3d-argocd-hub -n argocd get ingress
kubectl --context k3d-argocd-hub -n argocd get configmap \
  argocd-cm argocd-rbac-cm

./scripts/verify-keycloak-sso.sh
```

Do not print `keycloak-runtime`, `keycloak-realm-import`, or the Argo CD client
secret during ordinary inspection. Retrieve a login password only by following
the explicit command in the SSO guide.
