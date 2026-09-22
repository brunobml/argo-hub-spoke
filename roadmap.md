# Lab roadmap

This roadmap tracks the repeatable script-based path. To rebuild the same lab
one operation at a time, use [docs/manual-lab.md](docs/manual-lab.md). The
manual path explains what the scripts create and adds observation points
between changes.

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
| 6 | Start Moto and create a fake AWS secret | Complete |
| 7 | Install External Secrets Operator | Complete |
| 8 | Reconcile an ExternalSecret | Complete |
| 9 | Harden Argo CD spoke RBAC | Complete |
| 10 | Add `spoke-03` without changing ApplicationSet | Complete |
| 11 | Reliability, troubleshooting, and final validation | Planned |

The optional Keycloak SSO exercise is complete. It changes user authentication
to Argo CD but is not part of the application-delivery dependency chain.

## Before Phase 1 — prerequisite gate

Start from a workstation with Bash 4+, Docker, k3d, kubectl, Helm 3, the Argo
CD CLI, Git, curl, OpenSSL, and standard text/encoding utilities. The complete
list, official installation links, required host ports, and network
requirements are in the [README prerequisites](README.md#prerequisites).

From a fresh clone:

```bash
git clone git@github.com:brunobml/argo-hub-spoke.git
cd argo-hub-spoke
./scripts/check-prerequisites.sh
```

Do not begin Phase 1 unless every command is found, Docker is reachable, and
the Git working-tree check passes. Before Phase 4, also ensure the desired
branch is committed and pushed to a repository that Argo CD can reach.

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
./scripts/verify-phase6.sh
```

The verifier checks container health, secret metadata without printing its
value, and network reachability from both spoke clusters. The underlying
metadata command is:

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
./scripts/verify-phase7.sh
```

Verify:

```bash
kubectl --context k3d-spoke-01 -n external-secrets get pods
kubectl --context k3d-spoke-02 -n external-secrets get pods
```

Complete when the pinned ESO `v1.3.2` deployments are ready on both spokes.
The script also
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
./scripts/verify-phase8.sh
```

Verify on both spokes:

```bash
kubectl --context k3d-spoke-01 -n demo get secretstore,externalsecret
kubectl --context k3d-spoke-01 -n demo get secret demo-database
kubectl --context k3d-spoke-02 -n demo get secretstore,externalsecret
kubectl --context k3d-spoke-02 -n demo get secret demo-database
```

The Phase 8 verifier confirms both responses changed to `Secret loaded: yes`,
lists only the generated Secret's key names, and never exposes its values.

## Phase 9 — Harden spoke RBAC

**Purpose:** replace broad namespace bootstrap rules with an explicit resource
allowlist.

**Production concept:** centralized Argo CD increases hub blast radius. Each
spoke credential should have only the verbs and resources its applications
require.

Argo CD's cache must read all discoverable resource types in the managed
namespace. The hardened Role therefore grants `get/list/watch` across `demo`,
but mutation only for Services, Deployments, SecretStores, and ExternalSecrets.
It cannot modify Secrets or access cluster-scoped resources.

```bash
./scripts/harden-rbac.sh
./scripts/verify-phase9.sh
```

Verify expected access and denial:

```bash
kubectl --context k3d-spoke-01 auth can-i create deployments -n demo \
  --as=system:serviceaccount:kube-system:argocd-manager
kubectl --context k3d-spoke-01 auth can-i create namespaces \
  --as=system:serviceaccount:kube-system:argocd-manager
```

The first result should be `yes`; the second should be `no`. The Phase 9
verifier checks the complete allow/deny matrix, re-runs the Phase 8 checks, and
briefly scales `spoke-01` to five replicas to prove self-healing still works.

## Phase 10 — Add `spoke-03`

**Purpose:** prove that cluster labels, not a hardcoded cluster list, control
deployment placement.

**Production concept:** onboarding is create → register → label. ApplicationSet
reacts automatically.

```bash
./scripts/create-spoke.sh spoke-03 6553
./scripts/verify-phase10.sh
```

Verify:

```bash
kubectl --context k3d-argocd-hub -n argocd get applications
kubectl --context k3d-spoke-03 -n demo get deployment,pod,service
```

Complete when `demo-app-spoke-03` appears and becomes `Synced/Healthy` without
editing `bootstrap/hub/applicationset-external-secrets.yaml`.

## Phase 11 — Reliability, troubleshooting, and final validation

**Status:** Planned. Do not mark this phase complete until every completion
criterion below has been demonstrated from a clean rebuild.

**Purpose:** remove avoidable setup and verification failures, make error
messages actionable, and prove that a new learner can rebuild and troubleshoot
the lab. This phase does not add another platform component or change the
hub-and-spoke architecture.

**Production concept:** operational readiness includes deterministic
validation, useful failure signals, safe cleanup, credential hygiene, and a
documented recovery path—not only a successful initial deployment.

### Prerequisite learning pass

Before changing Phase 11 code:

1. Complete the [manual learning path](docs/manual-lab.md), concentrating on
   Phases 3, 5, 8, 9, and 10.
2. Run every exercise under [After the roadmap](#after-the-roadmap), one at a
   time, and restore the healthy state after each exercise.
3. Record commands, explanations, or expected results that were unclear.
4. Add those observations to the relevant Phase 11 task instead of adding a
   new component.

### Ordered implementation tasks

Complete these tasks in order and verify each one independently:

1. **Resilient asynchronous verification**
   - Add bounded retry loops to Phase 4, 5, and 8 verification.
   - Report the last observed sync, health, or readiness state on timeout.
   - Keep a real failure non-zero; retries must not hide errors.
2. **Portable Phase 10 verification**
   - Replace the undocumented `rg` dependency with `grep`.
   - Re-run Phase 10 verification on the existing healthy lab.
3. **Operation-specific port checks**
   - Check `80`, `443`, and `6550-6552` before initial cluster creation.
   - Check `5000` before creating Moto.
   - Check the requested API port before creating an additional spoke.
   - Distinguish an existing lab component from an unrelated process and give
     the learner a clear recovery instruction.
4. **Argo CD discovery-cache troubleshooting**
   - Document the transient state that can occur when ESO CRDs are installed
     after spoke registration.
   - Prefer a bounded wait or targeted hard refresh.
   - Keep application-controller restart as an explicit troubleshooting step,
     not an automatic side effect of ESO installation.
5. **Safe dynamic cleanup**
   - Support spokes beyond `spoke-03` without deleting unrelated k3d clusters.
   - Show the exact lab resources selected for deletion.
   - Require an explicit option before broad dynamic deletion.
6. **Safer Git defaults**
   - Preserve explicit `REPO_URL` and `TARGET_REVISION` overrides.
   - Optionally detect the origin and current branch when they are omitted.
   - Warn about a dirty tree, missing upstream, or unpushed commits.
   - Do not silently rewrite an SSH URL to HTTPS for a private repository.
7. **End-to-end validation summary**
   - Add a small `verify-lab.sh` that composes existing verification scripts
     instead of duplicating their assertions.
   - Print a concise pass/fail summary and exit non-zero on any failure.
   - Clearly identify checks that intentionally mutate state, such as the
     Phase 9 drift exercise.
8. **Credential hygiene**
   - Ensure local notes containing passwords cannot be committed accidentally.
   - Scan tracked changes for credentials before the final commit.
   - Rotate any credential that was written to an unsafe local file or shared.
   - Continue printing only Secret key names during normal verification.
9. **Documentation reconciliation**
   - Update the README, roadmap, manual tutorial, and troubleshooting guidance
     to match the implemented behavior.
   - Remove stale commands and duplicated or contradictory instructions.

### Verification sequence

After implementing the tasks:

```bash
bash -n scripts/*.sh
./scripts/check-prerequisites.sh
```

Then use `./scripts/cleanup.sh` only after reviewing what it will delete, and
perform a clean rebuild in roadmap order:

```text
Phase 1 -> Phase 2 -> Phase 3 -> Phase 4 -> Phase 5
        -> Phase 6 -> Phase 7 -> Phase 8 -> Phase 9 -> Phase 10
```

For each phase, run its documented verification before continuing. Finally,
run the new end-to-end validator and all failure exercises. Confirm that each
failure produces the documented symptom and that the lab returns to
`Synced/Healthy` afterward.

### Completion criteria

Phase 11 is complete only when:

- a fresh clone passes the prerequisite gate or clearly identifies what is
  missing;
- a clean rebuild completes Phases 1–10 in order;
- every phase verifier and the end-to-end validator passes;
- asynchronous reconciliation does not cause false-negative verification;
- port conflicts and Git publication mistakes produce actionable messages;
- self-healing, Moto outage, spoke outage, and label-placement exercises match
  the documentation;
- cleanup includes intentionally created lab spokes but protects unrelated
  clusters;
- no credential or application secret value is tracked by Git;
- the healthy final state has every generated Application `Synced/Healthy`;
- no new platform component was introduced.

When all criteria pass, change Phase 11 from `Planned` to `Complete` in the
progress table and in this section.

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
