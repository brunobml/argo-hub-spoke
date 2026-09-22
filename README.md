# Argo CD hub-and-spoke lab

Start with [roadmap.md](roadmap.md) for phase status, the next step, commands,
verification, and the production concept demonstrated by each exercise.

Two learning paths are available:

- Use the phase commands below for a fast, repeatable build.
- Use [docs/manual-lab.md](docs/manual-lab.md) to perform the same architecture
  one operation at a time and inspect what each script normally hides.

This lab runs one Argo CD control plane in `argocd-hub` and deploys a tiny
nginx application to `spoke-01` and `spoke-02`. External Secrets Operator
(ESO) runs on each spoke and reads a JSON secret from a local Moto container
that emulates AWS Secrets Manager.

The infrastructure is local; the architecture is not simplified:

```text
Git -> Argo CD hub -> spoke Kubernetes APIs
                         |
                         +-> demo app
                         +-> ESO -> Moto (AWS Secrets Manager API)
```

## Project status

The architecture and delivery work in Phases 1–10 is complete. Preparation for
Phase 11, a reliability, troubleshooting, and final-validation pass, is in
progress; it adds no new platform component. See the [roadmap](roadmap.md#phase-11--reliability-troubleshooting-and-final-validation)
for its prerequisite, ordered tasks, verification, and completion criteria.

## Prerequisites

Required workstation software:

- Bash 4 or newer;
- Docker with a running daemon;
- k3d;
- kubectl;
- Helm 3;
- Argo CD CLI;
- Git, curl, and OpenSSL;
- standard `base64`, `sed`, `awk`, and `grep` utilities.

Installation documentation:

- [Docker Engine](https://docs.docker.com/engine/install/)
- [k3d](https://k3d.io/stable/#installation)
- [kubectl](https://kubernetes.io/docs/tasks/tools/)
- [Helm](https://helm.sh/docs/intro/install/)
- [Argo CD CLI](https://argo-cd.readthedocs.io/en/stable/cli_installation/)

The workstation also needs:

- outbound access to GitHub, Helm repositories, and container registries;
- host ports `80`, `443`, `5000`, and `6550` through `6553` available when
  their corresponding lab components are created;
- this repository cloned locally;
- a pushed Git repository URL reachable by Argo CD before Phase 4.

The scripts are tested with Bash on Linux. Other operating systems may require
small command-line differences in the manual learning path.

After cloning, run the prerequisite check from the repository root:

```bash
git clone git@github.com:brunobml/argo-hub-spoke.git
cd argo-hub-spoke
./scripts/check-prerequisites.sh
```

Do not begin Phase 1 until every command reports `found` and the Docker daemon
and Git working tree checks pass. Automated host-port conflict detection is a
planned Phase 11 improvement; until then, free the listed ports before running
the lab.

## Walk through the phases

Do not run this as one opaque installer. Run a phase, inspect it, and verify it
before continuing.

Each section below is the **quick path**. For a progressive command-by-command
version, follow the matching phase in the
[manual learning path](docs/manual-lab.md).

### 1. Create the clusters

```bash
./scripts/create-clusters.sh
k3d cluster list
kubectl config get-contexts
```

All containers join the `argo-lab` Docker network. The fixed API ports are
`6550` (hub), `6551` (spoke-01), and `6552` (spoke-02). The hub also maps host
ports 80 and 443 to its Traefik load balancer for optional ingress-based UIs.

### 2. Install Argo CD only on the hub

**Goal:** create the single control plane that will later reconcile workloads
on both remote clusters. Nothing is installed on the spokes in this phase.

```bash
./scripts/install-argocd.sh
kubectl --context k3d-argocd-hub -n argocd get pods
```

The script installs the pinned upstream Argo CD `v3.1.8` manifest and waits for
both its Deployments and its application-controller StatefulSet. Pinning makes
the exercise repeatable; override it explicitly with `ARGO_CD_VERSION` when
testing an upgrade.

Important components to identify:

| Component | Lab responsibility |
|---|---|
| `argocd-server` | API and web UI |
| `argocd-repo-server` | fetches and renders Git content |
| `argocd-application-controller` | compares desired and live state and synchronizes it |
| `argocd-applicationset-controller` | later generates one Application per labeled spoke |
| `argocd-redis` | short-lived cache |
| `argocd-dex-server` | identity integration; local admin is used for this lab |
| `argocd-notifications-controller` | ships in the upstream manifest but is unused in this lab |

Verify that every pod is `Running`, the application controller is ready, and
Argo CD is absent from both spokes:

```bash
kubectl --context k3d-argocd-hub -n argocd get deploy,statefulset
kubectl --context k3d-argocd-hub get crd \
  applications.argoproj.io \
  applicationsets.argoproj.io \
  appprojects.argoproj.io
kubectl --context k3d-spoke-01 get namespace argocd
kubectl --context k3d-spoke-02 get namespace argocd
```

The last two commands should return `NotFound` and a non-zero exit status.
That is intentional: the hub will manage the spokes through their Kubernetes
APIs. Guard these negative checks if copying them into a `set -e` script.

To use the UI, start a port-forward in one terminal:

```bash
kubectl --context k3d-argocd-hub -n argocd port-forward svc/argocd-server 8080:443
```

In another terminal, obtain the bootstrap password and log in. Avoid copying
the password into documentation or Git:

```bash
argocd admin initial-password --core --kube-context k3d-argocd-hub
argocd login localhost:8080 --username admin --insecure
```

Open <https://localhost:8080>. The certificate warning is expected because the
local installation uses a self-signed certificate. No applications or remote
clusters are expected yet; those belong to later phases.

### 3. Register the spokes

**Goal:** give the hub an identity it can use against each spoke API, while
limiting that identity to the `demo` namespace.

```bash
./scripts/register-clusters.sh
./scripts/verify-phase3.sh
```

Registration consists of two sides:

```text
spoke-01 / spoke-02                    argocd-hub
-------------------                    ----------
kube-system/argocd-manager SA    --->  argocd/cluster-spoke-N Secret
demo Role + RoleBinding                 name, API URL, CA, token, labels
```

The upstream `argocd cluster add CONTEXT` command automates this model. This
lab creates it declaratively so each object is visible and the access is
namespace-scoped from the beginning. The hub Secrets use the required
`argocd.argoproj.io/secret-type=cluster` label and also contain:

- `environment=dev`
- `workload=applications`

The latter is the placement selector used by ApplicationSet in Phase 5. The
credential fields are base64-encoded Kubernetes Secret data and must not be
printed or committed.

The API address is `https://k3d-spoke-N-server-0:6443`, resolvable on the
shared Docker network. The workstation's `127.0.0.1:655N` address would not be
usable from an Argo CD pod.

Expected verification results:

- both `cluster-spoke-01` and `cluster-spoke-02` exist with both labels;
- each manager can create a Deployment in `demo`;
- each manager cannot create a Deployment in `default`;
- `argocd cluster list` shows both spokes and `(1 namespaces)`.

The cluster status may be `Unknown` with the message that it has no
applications and is not monitored. That is healthy at the end of Phase 3.
Phase 4 will create the first Application and activate monitoring.

### 4. Deploy one app manually through Argo CD

**Goal:** understand one `Application` completely before a generator creates
many of them. This phase targets only `spoke-01`.

Commit and push this repository first, then provide its HTTPS clone URL. A
public repository needs no Argo CD repository credential:

```bash
export REPO_URL=https://github.com/brunobml/argo-hub-spoke.git
export TARGET_REVISION=main
./scripts/bootstrap-gitops.sh manual
./scripts/verify-phase4.sh
```

This phase creates one `Application` for `spoke-01`, making the mechanics easy
to inspect before introducing ApplicationSet:

```text
Git apps/demo-app/base
          |
          v
argocd/Application demo-app-spoke-01
          |
          v
spoke-01/demo Deployment + Service
```

The Application has automated synchronization and `selfHeal: true`, but does
not enable pruning. Its Kustomize patch injects `spoke-01` into the generic
Deployment so the HTTP response identifies its target cluster.

Expected response at this point:

```text
Cluster: spoke-01
Environment: dev
Secret loaded: no
```

`Secret loaded: no` is intentional: Moto and ESO are Phases 6–8. The verifier
also confirms the app is absent from `spoke-02`; multi-cluster placement is
introduced only in Phase 5.

### 5. Replace it with an ApplicationSet Cluster Generator

**Goal:** use cluster registration metadata as the placement API. Adding a
matching cluster should produce an Application without editing this
ApplicationSet.

```bash
export REPO_URL=https://github.com/brunobml/argo-hub-spoke.git
export TARGET_REVISION=main
./scripts/bootstrap-gitops.sh applicationset
./scripts/verify-phase5.sh
```

The generator selects cluster Secrets labeled `workload=applications`. It does
not contain a list of spoke names:

```text
cluster-spoke-01 Secret --+
  workload=applications    |
                           +-> Cluster Generator -> demo-app-spoke-01
cluster-spoke-02 Secret --+                      -> demo-app-spoke-02
  workload=applications
```

For every match, the generator supplies `.name`, `.nameNormalized`, and
`.server`. The template uses the server as the destination and injects the
cluster name into the same generic Kustomize base. Both generated Applications
have an `ApplicationSet` owner reference and automated self-healing.

Expected responses are identical except for placement:

```text
spoke-01 -> Cluster: spoke-01
spoke-02 -> Cluster: spoke-02
```

Both still report `Secret loaded: no`; secret delivery has not been introduced
yet. Phase 10 will prove the scaling property with `spoke-03`, after the
remaining platform and security phases are understood.

### 6. Start Moto and create the fake AWS secret

Supply the application values at runtime; they are never stored in Git:

```bash
read -r -p 'Database username: ' DEMO_DB_USERNAME
read -r -s -p 'Database password: ' DEMO_DB_PASSWORD; echo
export DEMO_DB_USERNAME DEMO_DB_PASSWORD
./scripts/setup-moto.sh
./scripts/verify-phase6.sh
```

The secret key is `/demo/database`. The script prints metadata, never its
value. Verification also launches a short-lived curl pod in each spoke to prove
that Kubernetes workloads can resolve and reach `http://moto:5000` over the
shared Docker network.

### 7. Install ESO on both spokes

```bash
./scripts/install-eso.sh
./scripts/verify-phase7.sh
kubectl --context k3d-spoke-01 -n external-secrets get pods
kubectl --context k3d-spoke-02 -n external-secrets get pods
```

ESO `v1.3.2` is platform bootstrap in this small lab. Its provider objects and
the demo application remain GitOps-managed. Phase 7 intentionally ends before
creating a SecretStore or ExternalSecret.

### 8. Enable the ExternalSecret overlay

```bash
./scripts/bootstrap-gitops.sh external-secrets
./scripts/verify-phase8.sh
kubectl --context k3d-spoke-01 -n demo get secretstore,externalsecret
kubectl --context k3d-spoke-01 -n demo get secret demo-database
```

Do not decode the generated Secret during ordinary verification. Port-forward
the service only if you want to access it from a browser; the verifier uses the
Kubernetes API proxy and observes only whether a secret was loaded:

```bash
kubectl --context k3d-spoke-01 -n demo port-forward svc/demo-app 8081:80
curl http://localhost:8081
```

### 9. Harden Argo CD's spoke access

The CLI registration initially creates broad bootstrap permissions. Replace
them with a Role and RoleBinding limited to the pre-created `demo` namespace:

```bash
./scripts/harden-rbac.sh
./scripts/verify-phase9.sh
```

This installs an explicit resource allowlist and removes the broad namespace
bootstrap Role. Argo CD can read all resource types in `demo`, which its cluster
cache requires, but it can mutate only Services, Deployments, SecretStores, and
ExternalSecrets. It cannot alter Secrets or administer the rest of a spoke. The
script also cleans up a CLI-created ClusterRoleBinding if one was left by an
interrupted experiment. The verifier introduces temporary replica drift and
confirms that Argo CD restores the Git-defined replica count.

### 10. Add a spoke without changing ApplicationSet

```bash
./scripts/create-spoke.sh spoke-03 6553
./scripts/verify-phase10.sh
kubectl --context k3d-spoke-03 -n demo get pods
```

The script creates and registers the cluster, installs ESO, and applies the
same restricted RBAC. ApplicationSet discovers it through the cluster label.

## Drift and failure exercises

```bash
# Argo CD self-heal returns this to one replica.
kubectl --context k3d-spoke-01 -n demo scale deployment demo-app --replicas=5

# ESO reports provider errors; existing Kubernetes Secret remains.
docker stop moto
kubectl --context k3d-spoke-01 -n demo describe externalsecret demo-database
docker start moto

# One unavailable spoke does not stop reconciliation of another.
k3d cluster stop spoke-02
argocd cluster list --core --kube-context k3d-argocd-hub
k3d cluster start spoke-02
```

Automated sync uses self-healing but intentionally omits `prune: true`; this
introductory lab does not automatically delete resources removed from Git.

## Cleanup

```bash
./scripts/cleanup.sh
```

See [docs/architecture.md](docs/architecture.md) for the trust boundaries and
the local-to-production mapping.

## Optional extension: Keycloak SSO

After Phase 3, you may add Keycloak authentication without changing the spoke
architecture. Follow [docs/keycloak-sso.md](docs/keycloak-sso.md). This remains
outside the numbered application-delivery phases so the core hub-and-spoke
lesson does not depend on an identity platform.
