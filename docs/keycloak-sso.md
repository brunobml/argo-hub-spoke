# Optional lab: Keycloak single sign-on for Argo CD

This extension adds one Keycloak instance to `argocd-hub`. It is deliberately
optional: SSO changes how users authenticate to the hub but does not change how
Argo CD authenticates to the spoke Kubernetes APIs.

```text
browser -> Keycloak -> OIDC token -> Argo CD -> group RBAC
                                      |
                                      +-> existing spoke credentials
```

## Why add it?

It demonstrates the production concept of delegating authentication to an
identity provider and mapping identity-provider groups to Argo CD roles. The
lab uses two mappings:

| Keycloak group | Argo CD role |
|---|---|
| `argocd-admins` | `role:admin` |
| `argocd-viewers` | `role:readonly` |

The realm's protocol mapper adds `groups` as an ID-token claim. Argo CD asks
for the standard `openid`, `profile`, and `email` scopes and marks the groups
claim as required; `groups` is not requested as a standalone OAuth scope.

## Install

```bash
./scripts/install-keycloak-sso.sh
./scripts/verify-keycloak-sso.sh
```

The installer generates random passwords and an OIDC client secret unless
values are supplied through `KEYCLOAK_ADMIN_PASSWORD`,
`KEYCLOAK_DEVELOPER_PASSWORD`, `KEYCLOAK_VIEWER_PASSWORD`, and
`ARGOCD_OIDC_CLIENT_SECRET`. Generated values live only in Kubernetes Secrets.
The rendered realm import also lives in a Secret; Git contains placeholders.

Retrieve a password only when you need to log in:

```bash
# Admin user for Keycloak's management console
kubectl --context k3d-argocd-hub -n keycloak get secret keycloak-runtime \
  -o jsonpath='{.data.admin-password}' | base64 -d; echo

# Argo CD administrator through SSO (username: developer)
kubectl --context k3d-argocd-hub -n keycloak get secret keycloak-runtime \
  -o jsonpath='{.data.developer-password}' | base64 -d; echo

# Read-only Argo CD user (username: viewer)
kubectl --context k3d-argocd-hub -n keycloak get secret keycloak-runtime \
  -o jsonpath='{.data.viewer-password}' | base64 -d; echo
```

Do not paste these values into Git or documentation.

## Open the UIs

No port-forward is required. The hub maps host ports 80 and 443 to its k3d
load balancer, and Traefik routes requests by hostname:

- Argo CD: <http://argocd.localhost>
- Keycloak: <http://keycloak.localhost>

Choose **Log in via Keycloak** in Argo CD. Use `developer` to test admin
permissions and `viewer` to test read-only permissions. The original Argo CD
local admin remains available as a recovery path for this lab.

The issuer URL must be identical in the browser and inside the cluster. The
installer adds the same `.localhost` CoreDNS rewrite used by the reference lab,
so in-cluster clients resolve these names to Traefik while browsers resolve
them to localhost. If the browser does not resolve `.localhost` automatically,
add `127.0.0.1 argocd.localhost keycloak.localhost` to `/etc/hosts`.

## Lab versus production

This installation uses Keycloak `start-dev`, an embedded database, HTTP, and a
single replica. It is intentionally disposable. A production implementation
needs TLS, a persistent supported database such as PostgreSQL, backup and
restore, availability planning, external secret management, and carefully
scoped group ownership. None of those additions are needed to explain OIDC and
group RBAC in this lab.
