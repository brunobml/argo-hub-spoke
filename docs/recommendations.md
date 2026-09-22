# Lab Validation Report and Improvement Recommendations

This document details the end-to-end validation results of the **Argo CD Hub-and-Spoke Lab** across all phases (Phase 1 through Phase 10 plus the Keycloak SSO extension), documents key technical friction points identified during the live run, and provides actionable recommendations to enhance reliability, portability, and pedagogical value.

---

## 1. End-to-End Validation Summary

Every phase of the lab was executed sequentially on a clean environment following the documented roadmap. All phases succeeded and achieved their architectural goals.

| Phase | Description | Key Commands Executed | Validation Script | Result |
|---|---|---|---|---|
| **Phase 1** | Create 3 k3d clusters (`argocd-hub`, `spoke-01`, `spoke-02`) on Docker network `argo-lab` | `./scripts/create-clusters.sh` | `kubectl config get-contexts`<br>`kubectl get nodes` across contexts | **PASS** |
| **Phase 2** | Install pinned Argo CD v3.1.8 on `argocd-hub` only | `./scripts/install-argocd.sh` | `kubectl -n argocd get deploy,statefulset`<br>`kubectl --context k3d-spoke-01 get ns argocd` (NotFound) | **PASS** |
| **Phase 3** | Register and label spoke clusters with namespaced RBAC (`demo`) | `./scripts/register-clusters.sh` | `./scripts/verify-phase3.sh` (cluster list, labels, auth check in `demo` vs `default`) | **PASS** |
| **Phase 4** | Deploy manual Application targeting `spoke-01` | `./scripts/bootstrap-gitops.sh manual` | `./scripts/verify-phase4.sh` (HTTP proxy returns `Cluster: spoke-01`, absent on `spoke-02`) | **PASS** |
| **Phase 5** | Deploy `ApplicationSet` with Cluster Generator (`workload=applications`) | `./scripts/bootstrap-gitops.sh applicationset` | `./scripts/verify-phase5.sh` (both spokes generated, owned by ApplicationSet, Synced/Healthy) | **PASS** |
| **Phase 6** | Launch Moto container and create `/demo/database` secret | `./scripts/setup-moto.sh` | `./scripts/verify-phase6.sh` (describe secret metadata, spoke pods curl `http://moto:5000`) | **PASS** |
| **Phase 7** | Install External Secrets Operator (v1.3.2) Helm chart on spokes | `./scripts/install-eso.sh` | `./scripts/verify-phase7.sh` (ESO deployments, CRDs, endpoint `http://moto:5000`) | **PASS** |
| **Phase 8** | Enable ExternalSecret overlay via ApplicationSet | `./scripts/bootstrap-gitops.sh external-secrets` | `./scripts/verify-phase8.sh` (SecretStore/ExternalSecret Ready, `Secret loaded: yes`) | **PASS** *(see Note 1)* |
| **Phase 9** | Harden remote spoke RBAC (least-privilege namespace role) | `./scripts/harden-rbac.sh` | `./scripts/verify-phase9.sh` (can-i matrix, replica scale drift & self-heal test) | **PASS** |
| **Phase 10** | Add `spoke-03` dynamically without touching ApplicationSet | `./scripts/create-spoke.sh spoke-03 6553` | `./scripts/verify-phase10.sh` (auto-discovery, Synced/Healthy, `Secret loaded: yes`) | **PASS** *(see Note 2)* |
| **SSO Ext.**| Optional Keycloak OIDC authentication & group RBAC | `./scripts/install-keycloak-sso.sh` | `./scripts/verify-keycloak-sso.sh` (OIDC well-known endpoint, Ingress, RBAC mapping) | **PASS** |

---

## 2. Key Findings & Friction Points Discovered

### Finding 1: Phase 8 Reconciliation Timing
* **What Happened**: Immediately after changing the ApplicationSet in Phase 8, verification could run before Argo CD had created the `SecretStore` and `ExternalSecret`. The manual tutorial's original `kubectl wait` commands then returned `NotFound` immediately rather than waiting for the objects. An early application check could likewise report a transitional state such as:
  ```text
  [spoke-01]
  Application: sync=Synced health=Degraded
  ```
  In the clean manual reproduction, the objects appeared during normal reconciliation and both spokes reached `Synced/Healthy`, with `SecretStore` and `ExternalSecret` reporting `Ready: True` and the application serving `Secret loaded: yes`, without a controller restart.
* **Reproduced Root Cause**: A clean manual run showed that the ApplicationSet template update had not yet produced the `SecretStore` and `ExternalSecret` when the next commands ran. `kubectl wait --for=condition=Ready <named-resource>` does not wait for that resource to be created; it returns `NotFound` immediately. Normal Argo CD reconciliation created the resources and all Applications reached `Synced/Healthy` in under two minutes without restarting a controller. The earlier cache explanation was an inference and is superseded by this direct reproduction.
* **Phase 10 Sequencing**: `scripts/create-spoke.sh` installs ESO *before* running `register-clusters.sh`:
  ```bash
  # Platform CRDs must exist before the workload label makes ApplicationSet
  # discover this cluster.
  ./scripts/install-eso.sh "$name"
  ./scripts/register-clusters.sh "$name"
  ```
  This remains the correct dependency order because the CRDs exist before an
  Application can target the new spoke. It is not, by itself, evidence that a
  stale discovery cache caused the Phase 8 delay.
* **Solution**: Poll with a bounded timeout until the resources exist, then use `kubectl wait` for their `Ready` conditions. A targeted hard refresh is a reasonable troubleshooting action if convergence exceeds the documented timeout. Do not restart the application controller as a normal ESO installation step.

---

### Finding 2: Missing Host Port Pre-flight Checks
* **What Happened**: `scripts/create-clusters.sh` binds host ports `80` and `443` for `argocd-hub`, and ports `6550`, `6551`, `6552` (and `6553` for `spoke-03`). `scripts/setup-moto.sh` binds port `5000`.
* **Issue**: `scripts/check-prerequisites.sh` verifies tool binaries and docker reachability, but does not check if host ports `80`, `443`, `5000`, or `6550-6553` are already bound by local services (e.g. Apache, Nginx, Docker desktop, local registry, or other development tools). If port 80 is occupied, `k3d cluster create` fails midway.
* **Solution**: Add a non-invasive port availability check to `scripts/check-prerequisites.sh`.

---

### Finding 3: Tool Dependency Discrepancy (`rg` in `verify-phase10.sh`)
* **What Happened**: `scripts/verify-phase10.sh` uses `rg -q 'spoke-03'` on line 6.
* **Issue**: Ripgrep (`rg`) is not part of POSIX standard utilities and is not checked by `scripts/check-prerequisites.sh`. If a user runs the lab on a clean Debian/Ubuntu/Fedora/macOS workstation where only GNU grep is installed, Phase 10 verification fails with `command not found: rg`.
* **Solution**: Replace `rg -q` with standard POSIX `grep -Fq` or add `rg` to `check-prerequisites.sh`.

---

### Finding 4: Verification Script Race Conditions and Retries
* **What Happened**: `scripts/verify-phase4.sh`, `scripts/verify-phase5.sh`, and `scripts/verify-phase8.sh` check application status once and immediately call `exit 1` if the status is not yet `Synced` and `Healthy`.
* **Issue**: Because GitOps reconciliation and pod readiness are asynchronous, running the verification script immediately after `bootstrap-gitops.sh` can result in a false-negative failure simply because the loop evaluated a fraction of a second before Argo CD finished its sync cycle. By contrast, `scripts/verify-phase9.sh` employs a resilient retry loop (`for _ in $(seq 1 60); do ... sleep 3`).
* **Solution**: Standardize a retry loop with a short timeout across all verification scripts.

---

### Finding 5: Static Cluster List in `cleanup.sh`
* **What Happened**: `scripts/cleanup.sh` runs:
  ```bash
  for cluster in argocd-hub spoke-01 spoke-02 spoke-03; do
    k3d cluster delete "$cluster" 2>/dev/null || true
  done
  ```
* **Issue**: If a user experiments with scaling beyond Phase 10 (e.g., `spoke-04`, `spoke-05`, or custom names), `cleanup.sh` will leave orphaned clusters running.
* **Solution**: Make `cleanup.sh` dynamically query and delete any k3d cluster matching the lab pattern (`argocd-hub` or `spoke-*`), or provide an option to clean up all clusters on network `argo-lab`.

---

### Finding 6: Git Remote and Branch Auto-Detection
* **What Happened**: `bootstrap-gitops.sh` requires explicit environment variables:
  ```bash
  : "${REPO_URL:?Set REPO_URL to the pushed Git repository URL}"
  revision=${TARGET_REVISION:-HEAD}
  ```
* **Opportunity**: In most developer setups, the repository URL is already defined in `git remote get-url origin`, and the current branch is `git branch --show-current`. If `REPO_URL` is unset, the script can default to origin's HTTPS URL (or prompt), and warn if there are uncommitted or unpushed changes.

---

### Finding 7: Subdomain Resolution for `*.localhost` (Keycloak SSO)
* **What Happened**: Keycloak SSO tests `http://keycloak.localhost` and `http://argocd.localhost`.
* **Observation**: On modern Linux with `systemd-resolved`, `*.localhost` resolves automatically to `127.0.0.1` and `::1`. However, curl might attempt `[::1]:80` first before falling back to `127.0.0.1:80`. On some platforms or older setups without wildcards in `/etc/hosts` or systemd-resolved, `keycloak.localhost` may fail to resolve.
* **Solution**: Add an informational note or fallback in `verify-keycloak-sso.sh` that checks DNS resolution and suggests adding `/etc/hosts` entries if unresolvable.

---

## 3. Concrete Improvement Patches

Below are recommended implementations for the identified improvements.

### Improvement 1: Wait for Phase 8 Resources to Exist
After changing the ApplicationSet, allow Argo CD time to create the resources before waiting for their readiness:

```bash
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
```

---

### Improvement 2: Port Pre-flight Check in `scripts/check-prerequisites.sh`
Detect if required host ports are already bound before beginning cluster creation:

```bash
# Add to scripts/check-prerequisites.sh:
ports=(80 443 5000 6550 6551 6552 6553)
busy_ports=()
for port in "${ports[@]}"; do
  if ss -tulpn 2>/dev/null | grep -qE ":${port}\b"; then
    busy_ports+=("$port")
  fi
done

if (( ${#busy_ports[@]} )); then
  echo "WARNING: The following ports are already in use on the host: ${busy_ports[*]}" >&2
  echo "Ensure they are freed before running Phase 1 (k3d cluster creation)." >&2
fi
```

---

### Improvement 3: Replace `rg` with `grep` in `scripts/verify-phase10.sh`
Ensure compatibility on environments without ripgrep installed:

```diff
--- a/scripts/verify-phase10.sh
+++ b/scripts/verify-phase10.sh
@@ -3,9 +3,8 @@ set -euo pipefail

 hub_context=k3d-argocd-hub

-if rg -q 'spoke-03' \
-  bootstrap/hub/applicationset.yaml \
-  bootstrap/hub/applicationset-external-secrets.yaml; then
+if grep -Eq 'spoke-03' \
+  bootstrap/hub/applicationset.yaml bootstrap/hub/applicationset-external-secrets.yaml; then
   echo "spoke-03 must not be hardcoded in an ApplicationSet" >&2
   exit 1
 fi
```

---

### Improvement 4: Retry Loop in `scripts/verify-phase8.sh`
Avoid transient synchronization failures by allowing up to 30 seconds for reconciliation:

```bash
# Replace single-shot check in scripts/verify-phase8.sh with:
for spoke in spoke-01 spoke-02; do
  app="demo-app-${spoke}"
  echo "Waiting for $app to become Synced and Healthy..."
  ready=false
  for _ in $(seq 1 30); do
    sync=$(kubectl --context "$hub_context" -n argocd get application "$app" \
      -o jsonpath='{.status.sync.status}' 2>/dev/null || true)
    health=$(kubectl --context "$hub_context" -n argocd get application "$app" \
      -o jsonpath='{.status.health.status}' 2>/dev/null || true)
    if [[ "$sync" == Synced && "$health" == Healthy ]]; then
      ready=true
      break
    fi
    sleep 2
  done
  if [[ "$ready" != true ]]; then
    echo "$app failed to reach Synced and Healthy state (sync=$sync health=$health)" >&2
    exit 1
  fi
...
```

---

### Improvement 5: Dynamic Cluster Cleanup in `scripts/cleanup.sh`
Ensure any dynamically created spoke cluster is removed:

```bash
#!/usr/bin/env bash
set -euo pipefail

clusters=$(k3d cluster list --no-headers 2>/dev/null | awk '{print $1}' | grep -E '^(argocd-hub|spoke-)' || true)
for cluster in $clusters; do
  echo "Deleting cluster: $cluster"
  k3d cluster delete "$cluster" 2>/dev/null || true
done
docker rm -f moto 2>/dev/null || true
docker network rm argo-lab 2>/dev/null || true
echo "Removed all lab clusters, Moto, and the argo-lab network."
```

---

### Improvement 6: Smart Git Default Detection in `scripts/bootstrap-gitops.sh`
Reduce manual boilerplate while preserving explicit override support:

```bash
# In scripts/bootstrap-gitops.sh:
if [[ -z "${REPO_URL:-}" ]]; then
  default_url=$(git remote get-url origin 2>/dev/null || true)
  if [[ "$default_url" =~ ^git@github\.com:(.+)\.git$ ]]; then
    REPO_URL="https://github.com/${BASH_REMATCH[1]}.git"
  elif [[ "$default_url" =~ ^https:// ]]; then
    REPO_URL="$default_url"
  fi
fi
: "${REPO_URL:?Set REPO_URL or configure a git remote origin}"

if [[ -z "${TARGET_REVISION:-}" ]]; then
  TARGET_REVISION=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "HEAD")
fi
```

---

## 4. Architectural & Pedagogical Observations

1. **Alignment with AGENTS.md**:
   * The lab strictly obeys the rule: *"Fake the infrastructure, not the architecture"*.
   * Central control plane isolation is maintained: spoke clusters never run Argo CD components.
   * Remote cluster registration is completely declarative using native Kubernetes Secrets in `argocd` namespace.
   * External Secrets Operator keeps credentials entirely separated from Git: Git stores only secret references (`/demo/database`), while runtime values stay in Moto / Kubernetes Secrets.

2. **Pedagogical Clarity**:
   * Progressing from manual `Application` (Phase 4) to `ApplicationSet` (Phase 5) is one of the strongest learning moments. It clearly demonstrates the maintenance overhead of managing individual Application manifests versus letting the Cluster Generator scale dynamically.
   * Phase 9 (RBAC hardening) demonstrates real blast-radius reduction. The demonstration of breaking out of broad cluster-admin and proving that Argo CD cannot mutate Kubernetes Secrets or create cluster-wide objects is exceptional.
   * Phase 10 proves the power of label-based discovery: a single script command provisions a cluster and brings up the application with zero changes to any Git repository or ApplicationSet YAML.

3. **Conclusion**:
   The lab is robust, architecturally sound, and directly represents a production multi-cluster hub-and-spoke deployment. Applying the minor resilience and pre-flight enhancements detailed above will ensure a seamless experience across all developer environments.
