# Architecture and trust boundaries

## What is real

Argo CD runs only on `argocd-hub`. Its application controller uses credentials
stored in labeled Kubernetes Secrets in the hub's `argocd` namespace to call
each spoke API. ApplicationSet reads those same Secrets and emits one
`Application` per cluster labeled `workload=applications`.

ESO runs on each spoke. A namespace-scoped `SecretStore` identifies AWS
Secrets Manager and a namespace-scoped `ExternalSecret` identifies
`/demo/database`. ESO creates `demo-database`; Git never contains its value.

```text
source of truth                    runtime credentials / values
---------------                    ----------------------------
Git: workloads and references      hub: spoke service-account tokens
                                   Moto: application secret values
                                   spokes: ESO's generated Secret
```

## What is faked

| Local lab | Production analogue |
|---|---|
| k3d hub | management EKS cluster |
| k3d spokes | workload EKS clusters |
| shared Docker network | routed VPC/network connectivity |
| Moto | AWS Secrets Manager |
| fake static AWS keys | pod identity / IAM role |

The fake AWS keys are required only because an AWS SDK signs requests even
when talking to Moto. A production store should use EKS Pod Identity or IRSA
and an IAM policy limited to the required secret paths.

## Bootstrap boundary

The scripts create clusters, install the first Argo CD instance, register
cluster credentials, start Moto, and install ESO. Those actions must exist
before their controllers can reconcile anything. The `AppProject`,
`ApplicationSet`, application, `SecretStore`, and `ExternalSecret` are then
reconciled from Git.

## Network paths

- Argo CD reaches `https://k3d-spoke-N-server-0:6443` on `argo-lab`.
- ESO reaches `http://moto:5000` on `argo-lab`.
- Workstation tools use the fixed localhost API ports.

`localhost` inside a pod or container is that pod or container, not the host.

## Central-controller blast radius

Compromise of the hub can affect every registered spoke within the permissions
of its stored credentials. Phase 9 limits each credential to namespaced demo
resources. Production designs should also isolate projects, repositories,
teams, and environments, rotate credentials, audit access, and consider
multiple Argo CD control planes when the trust boundaries demand it.
