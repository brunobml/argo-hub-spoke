# Lab roadmap

This is the progress map for the Argo CD hub-and-spoke lab. Complete phases in
order: each phase introduces one production concept and has a clear verification
point before the next concept is added.

## Current progress

| Phase | Topic | Status |
|---|---|---|
| 1 | Create three k3d clusters | Complete |
| 2 | Install Argo CD on the hub | Complete |
| 3 | Register and label the spokes | Complete |
| 4 | Deploy one manual Argo CD Application | Complete |
| 5 | Replace it with an ApplicationSet | Complete |
| 6 | Start Moto and create a fake AWS secret | Next |
| 7 | Install External Secrets Operator | Pending |
| 8 | Reconcile an ExternalSecret | Pending |
| 9 | Harden Argo CD spoke RBAC | Pending |
| 10 | Add `spoke-03` without changing ApplicationSet | Pending |

The optional Keycloak SSO exercise is complete. It changes user authentication
to Argo CD but is not part of the application-delivery dependency chain.

## Architecture at a glance

```text
GitHub
  |
  v
argocd-hub
  Argo CD + ApplicationSet + optional Keycloak
  |                                      
  +--------------------+--------------------+
  | Kubernetes API     | Kubernetes API     |
  v                    v                    |
spoke-01             spoke-02               |
  demo-app             demo-app             |
  ESO                   ESO                 |
  +---------------------+--------------------+
                        |
                        v
                 Moto Secrets Manager
```

## Phase 1 — Create the clusters

**Purpose:** create a management cluster and two workload clusters while
keeping their roles visibly separate.

**Production concept:** a management EKS cluster and multiple workload EKS
clusters. k3d replaces infrastructure, not architecture.

```bash
./scripts/create-clusters.sh
```

Verify:

```bash
k3d cluster list
kubectl --context k3d-argocd-hub get nodes
kubectl --context k3d-spoke-01 get nodes
kubectl --context k3d-spoke-02 get nodes
```

Complete when all three server nodes are `Ready`. They share the `argo-lab`
Docker network, allowing cluster API and Moto communication.

## Phase 2 — Install Argo CD only on the hub

**Purpose:** establish one centralized GitOps control plane.

**Production concept:** a hub Argo CD controls remote workload clusters; Argo
CD does not need to run on every spoke.

```bash
./scripts/install-argocd.sh
```

Verify:

```bash
kubectl --context k3d-argocd-hub -n argocd get pods
kubectl --context k3d-spoke-01 get namespace argocd
kubectl --context k3d-spoke-02 get namespace argocd
```

All hub pods must be ready. The two spoke namespace checks should return
`NotFound`.

## Phase 3 — Register and label the spokes

**Purpose:** give the hub authenticated, namespace-scoped API access to each
spoke and attach placement metadata.

**Production concept:** Argo CD stores remote cluster connection configuration
in labeled Secrets. ApplicationSet later reads the same Secrets.

```bash
./scripts/register-clusters.sh
./scripts/verify-phase3.sh
```

Registration creates:

- an `argocd-manager` ServiceAccount on each spoke;
- a Role and RoleBinding in each `demo` namespace;
- `cluster-spoke-01` and `cluster-spoke-02` Secrets on the hub;
- `environment=dev` and `workload=applications` labels.

Complete when both clusters appear in Argo CD and authorization is allowed in
`demo` but denied in `default`.

## Phase 4 — Deploy one manual Application

**Purpose:** understand one Argo CD Application before adding generation.

**Production concept:** Git is desired state; the hub renders Git content and
applies it through the registered spoke credential.

```bash
export REPO_URL=https://github.com/brunobml/argo-hub-spoke.git
export TARGET_REVISION=main
./scripts/bootstrap-gitops.sh manual
./scripts/verify-phase4.sh
```

Only `spoke-01` receives the Deployment and Service. The response should be:

```text
Cluster: spoke-01
Environment: dev
Secret loaded: no
```

The missing secret is expected because Moto and ESO do not exist yet.

## Phase 5 — Use an ApplicationSet Cluster Generator

**Purpose:** replace the manually named target with label-driven placement.

**Production concept:** ApplicationSet discovers registered clusters and emits
one Application per match. New matching clusters require no template change.

```bash
export REPO_URL=https://github.com/brunobml/argo-hub-spoke.git
export TARGET_REVISION=main
./scripts/bootstrap-gitops.sh applicationset
./scripts/verify-phase5.sh
```

Complete when `demo-app-spoke-01` and `demo-app-spoke-02` are both generated,
owned by the ApplicationSet, `Synced`, and `Healthy`.

## Phase 6 — Start Moto

**Purpose:** provide a local AWS Secrets Manager-compatible API without putting
application values in Git.

**Production concept:** Moto stands in for AWS Secrets Manager. The API flow is
representative even though authentication uses fake local credentials.

Set secret values only in the current shell:

```bash
read -r -p 'Database username: ' DEMO_DB_USERNAME
read -r -s -p 'Database password: ' DEMO_DB_PASSWORD; echo
export DEMO_DB_USERNAME DEMO_DB_PASSWORD
./scripts/setup-moto.sh
```

Verify container health and secret metadata without printing its value:

```bash
docker ps --filter name=moto
docker run --rm --network argo-lab \
  -e AWS_ACCESS_KEY_ID=moto \
  -e AWS_SECRET_ACCESS_KEY=moto \
  -e AWS_DEFAULT_REGION=us-east-1 \
  amazon/aws-cli:2.31.18 \
  --endpoint-url http://moto:5000 secretsmanager describe-secret \
  --secret-id /demo/database
```

Complete when Moto is running on `argo-lab` and `/demo/database` exists. Do not
commit or unnecessarily display its value.

## Phase 7 — Install External Secrets Operator

**Purpose:** install the controller that translates an ExternalSecret reference
into a Kubernetes Secret.

**Production concept:** ESO runs in each workload cluster and authenticates to
an external secret provider. It is not an Argo CD component.

```bash
./scripts/install-eso.sh
```

Verify:

```bash
kubectl --context k3d-spoke-01 -n external-secrets get pods
kubectl --context k3d-spoke-02 -n external-secrets get pods
```

Complete when the ESO deployments are ready on both spokes. The script also
creates fake AWS SDK credentials imperatively in each `demo` namespace; those
values work only with Moto and are not committed.

## Phase 8 — Enable ExternalSecret reconciliation

**Purpose:** let Git describe the secret reference while ESO supplies the
runtime value.

**Production concept:** Git contains `/demo/database` and property names, never
the username or password. A namespace-scoped SecretStore limits the provider
configuration's scope.

```bash
export REPO_URL=https://github.com/brunobml/argo-hub-spoke.git
export TARGET_REVISION=main
./scripts/bootstrap-gitops.sh external-secrets
```

Verify on both spokes:

```bash
kubectl --context k3d-spoke-01 -n demo get secretstore,externalsecret
kubectl --context k3d-spoke-01 -n demo get secret demo-database
kubectl --context k3d-spoke-02 -n demo get secretstore,externalsecret
kubectl --context k3d-spoke-02 -n demo get secret demo-database
```

Then run `./scripts/verify-phase5.sh` again. Both responses should change to
`Secret loaded: yes` without exposing the actual secret.

## Phase 9 — Harden spoke RBAC

**Purpose:** replace broad namespace bootstrap rules with an explicit resource
allowlist.

**Production concept:** centralized Argo CD increases hub blast radius. Each
spoke credential should have only the verbs and resources its applications
require.

```bash
./scripts/harden-rbac.sh
```

Verify expected access and denial:

```bash
kubectl --context k3d-spoke-01 auth can-i create deployments -n demo \
  --as=system:serviceaccount:kube-system:argocd-manager
kubectl --context k3d-spoke-01 auth can-i create namespaces \
  --as=system:serviceaccount:kube-system:argocd-manager
```

The first result should be `yes`; the second should be `no`. Re-run the
application and ExternalSecret checks to ensure least privilege did not break
reconciliation.

## Phase 10 — Add `spoke-03`

**Purpose:** prove that cluster labels, not a hardcoded cluster list, control
deployment placement.

**Production concept:** onboarding is create → register → label. ApplicationSet
reacts automatically.

```bash
./scripts/create-spoke.sh spoke-03 6553
```

Verify:

```bash
kubectl --context k3d-argocd-hub -n argocd get applications
kubectl --context k3d-spoke-03 -n demo get deployment,pod,service
```

Complete when `demo-app-spoke-03` appears and becomes `Synced/Healthy` without
editing `bootstrap/hub/applicationset-external-secrets.yaml`.

## Optional extension — Keycloak SSO

**Status:** Complete.

**Purpose:** delegate Argo CD user authentication to an OIDC provider and map
identity groups to Argo CD roles.

```bash
./scripts/install-keycloak-sso.sh
./scripts/verify-keycloak-sso.sh
```

- Argo CD: <http://argocd.localhost>
- Keycloak: <http://keycloak.localhost>

See [docs/keycloak-sso.md](docs/keycloak-sso.md). SSO is independent of the
credentials Argo CD uses to manage spoke APIs.

## After the roadmap

Useful demonstrations after all phases work:

- manually scale a managed Deployment and observe self-healing;
- stop Moto and inspect ESO provider errors;
- stop one spoke and confirm the other continues reconciling;
- remove `workload=applications` from a cluster Secret and inspect placement;
- discuss when separate Argo CD control planes provide a better trust boundary.
