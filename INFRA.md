# Workshop Infrastructure — Kind Cluster Setup

Scripts that provision the two-cluster ambient mesh environment for this workshop on a local machine using [kind](https://kind.sigs.k8s.io/).

## Workshop part status

| Part | Status |
|---|---|
| 1 — Mesh & multi-cluster by labeling | ✅ Verified |
| 2 — Identity-based authorization | ✅ Verified |
| 3 — Workload-identity claims in the SVID | ✅ Verified |
| 4 — Identity beyond the mesh (WIT egress) | ✅ Verified |
| 5 — On-behalf-of token exchange | ✅ Verified |

## Prerequisites

| Tool | Notes |
|---|---|
| `kind` | `brew install kind` |
| `docker` | Docker Desktop or equivalent |
| `helm` | v3.x |
| `kubectl` | in PATH |
| `gcloud` | authenticated (`gcloud auth login`) — needed to pull EAG images from `us-central1-docker.pkg.dev` |
| `GLOO_MESH_LICENSE` | exported before running setup |

The `certs/` directory from **`ambient-multicluster-workshop`** must be present as a sibling directory:

```
github.com/rvennam/
  ambient-multicluster-workshop/   ← pre-req; provides certs/cluster{1,2}/
  istio-agentgateway-identity-workshop/   ← this repo
```

## Usage

**From-scratch bring-up + validate everything:**
```bash
source ~/bin/gloo-mesh-license-env   # sets GLOO_MESH_LICENSE
./teardown.sh                        # nuke any existing kind-cluster1/2
./setup.sh                           # ~5–7 min — infra only, no workshop content
export CLUSTER1=kind-cluster1
export CLUSTER2=kind-cluster2
./parts/runall.sh                    # ~3–4 min — runs Parts 1-5 and asserts each
```

**Re-validate without rebuilding infra** (faster, ~1 min for the wipe + ~1 min for runall):
```bash
./reset-workshop.sh                  # delete the 6 workshop namespaces on both clusters
                                     # (keeps Istio, EAG, multicluster peering intact)
./parts/runall.sh                    # rebuild and re-validate everything
```
Use this when you've completed `setup.sh` once and want to re-run the workshop content
without paying the ~5–7 min cost of recreating kind clusters and reinstalling Istio.

**Run an individual part:**
```bash
./parts/01-multicluster.sh
./parts/02-identity-authz.sh
./parts/03-workload-claims.sh
./parts/04-egress-wit.sh
./parts/05-obo-token-exchange.sh
```
Each script is idempotent (re-running is safe) but builds on the previous part's state.
Run them in order on a fresh `setup.sh` (or after `reset-workshop.sh`).

**Manual walk-through** (no scripts): follow `README.md` after exporting `CLUSTER1` /
`CLUSTER2`. The READMEs commands and the part scripts apply the same resources.

---

## What setup.sh builds

```
Phase 1  kind clusters         kind-cluster1 + kind-cluster2 (Kubernetes 1.35)
Phase 2  MetalLB               LoadBalancer IPs for east-west gateways (172.18.255.200–240)
Phase 3  Shared root CA        certs/cluster{1,2}/ → cacerts secrets in istio-system
Phase 4  Solo Istio 1.30.0     gloo-operator 0.5.2 + ServiceMeshController
                                ENABLE_WORKLOAD_CLAIMS=true on istiod + ztunnel
Phase 5  East-west gateways    istio-eastwest + istio-remote-peer-cluster{1,2}
Phase 6  Multicluster secrets  istio.io/multiCluster secrets for workload endpoint discovery
Phase 7  Enterprise agentgateway  2026.6.0-alpha-6cb5709 (CRDs + controller on cluster1)
                                  Token exchange STS configured for Part 5 (see Token exchange section)
```

`setup.sh` provisions **only** the infrastructure. It does not deploy workshop apps,
authorization policies, or Part 5 IdP/agents — those live in `./parts/*.sh` so each
part can be exercised and validated independently.

**Cluster topology:**
| | cluster1 (`kind-cluster1`) | cluster2 (`kind-cluster2`) |
|---|---|---|
| Trust domain | `cluster1.local` | `cluster2.local` |
| East-west GW | `172.18.255.200` | `172.18.255.221` |
| Istio revision | `gloo` | `gloo` |
| EAG | yes | — |

---

## Non-obvious gotchas (recorded from the initial bring-up)

### 1 · Trust domain annotation must include `.local`

The remote peer `Gateway` annotation **must** use the full trust domain string:

```yaml
# CORRECT
gateway.istio.io/trust-domain: cluster1.local

# WRONG — causes SPIFFE SAN mismatch and connection reset
gateway.istio.io/trust-domain: cluster1
```

Without `.local`, ztunnel expects `spiffe://cluster1/ns/...` but the east-west gateway
presents `spiffe://cluster1.local/ns/...` — you'll see this in ztunnel logs:
```
identity verification error: peer did not present the expected SAN
  (spiffe://cluster1/ns/...), got spiffe://cluster1.local/ns/...
```

### 2 · Use `istio.io/multiCluster` secrets, not a mounted kubeconfig file

Istiod has `KUBECONFIG=/var/run/secrets/remote/config` in its env. If you create a secret
named `istio-kubeconfig` (which that env var expects), it **replaces** the pod's in-cluster
credentials for ALL API access — including the local cluster. Istiod then tries to use the
remote SA's token to reach its own API and gets permission errors.

The correct pattern is `istio.io/multiCluster`-typed secrets:
```yaml
type: istio.io/multiCluster
metadata:
  labels:
    istio.io/owned-by: istio-multicluster
```
Istiod watches these via its legacy multicluster controller and uses them only for
remote-cluster access, leaving in-cluster credentials intact for local access.

### 3 · Both peering AND legacy multicluster must be active simultaneously

`ENABLE_PEERING_DISCOVERY=true` handles service-level discovery (creates
`mesh.internal` hostnames via the xDS channel). The `istio.io/multiCluster` secrets handle
**workload endpoint** discovery (pod IPs, networks, SPIFFE identities). You need both.

Setting `DISABLE_LEGACY_MULTICLUSTER=true` suppresses the secrets and leaves ztunnel
without pod endpoints — traffic hits the east-west gateway and is reset.

### 4 · Global service needs both labels

`istiod`'s `serviceScopeConfigs` watches for `istio.io/global=true`, not `solo.io/service-scope=global`. The gloo-operator controller translates `solo.io/service-scope=global` → `istio.io/global=true` in some deployments, but for safety the workshop README applies both:

```bash
kubectl label svc cardholder -n tenant-payments \
  solo.io/service-scope=global istio.io/global=true --overwrite
```

### 5 · Enterprise agentgateway needs a separate CRDs chart

The main `enterprise-agentgateway` chart does **not** include CRDs. Install separately:
```bash
helm upgrade -i enterprise-agentgateway-crds \
  oci://.../charts/enterprise-agentgateway-crds --version <same-version>
```
Without the CRDs, the controller loops on "failed to list AgentgatewayPolicy / AgentgatewayBackend" errors.

### 6 · Token exchange crashes without an `issuer` config

Setting `tokenExchange.enabled=true` without additional configuration causes:
```
error starting token exchange server: invalid token exchange server config: issuer is required
```
The fix for Part 5 is to create a `configSecret` with the full JSON config including
`"issuer": "enterprise-agentgateway.agentgateway-system.svc.cluster.local:7777"`.
The setup script leaves `tokenExchange.enabled=false`; enable it during Part 5.

### 7 · EAG controller needs `istio.*` helm values for Part 4

By default the EAG controller generates gateway pods with:
- `TRUST_DOMAIN=cluster.local`  (wrong — ours is `cluster1.local`)
- `CA_ADDRESS=https://istiod.istio-system.svc:15012`  (wrong — service is `istiod-gloo`)

The gateway pod then fails to fetch its SVID (`backends required DNS resolution which failed`)
and resets every connection. The egress test in Part 4 fails with `Recv failure: Connection reset by peer`.

Set these on the EAG helm install:
```
--set istio.autoEnabled=true
--set istio.revision=gloo
--set istio.clusterId=cluster1
--set istio.network=cluster1
--set istio.caAddress="https://istiod-gloo.istio-system.svc:15012"
```
The controller pulls `TRUST_DOMAIN` from istiod's mesh config once it can reach the right address.

### 8 · GLOO_MESH_LICENSE vs EAG license

The `GLOO_MESH_LICENSE` JWT has `"product":"gloo-mesh"`. The enterprise agentgateway
controller validates this and logs warnings:
```
license validation failed: Invalid license detected ... degraded functionality
```
The controller still starts and the `enterprise-agentgateway-waypoint` GatewayClass
reaches `Accepted: True`. The workshop runs fine with these warnings in place.
For production use you'd need an EAG-specific license key.

### 9 · MetalLB needs non-overlapping IP ranges

Kind clusters share the Docker `kind` bridge network (`172.18.0.0/16`). Nodes take the
low IPs (`.2`–`.10`). The script carves out `.255.200–.220` for cluster1 and `.221–.240`
for cluster2 — well above any node IP. If your Docker network is different, adjust
`C1_METALLB` / `C2_METALLB` in `setup.sh`.

### 10 · CA fingerprint must come from `--minify`

`kubectl config view --raw -o jsonpath='{.clusters[0]...}'` can pick up the **wrong** CA if
the kubeconfig contains multiple cluster entries (e.g., Docker Desktop, GKE). Always use
`--minify` to scope to the specific context:
```bash
kubectl config view --context kind-cluster2 --raw --minify \
  -o jsonpath='{.clusters[0].cluster.certificate-authority-data}'
```

### 11 · `istioctl multicluster` requires 1.28+

The bundled `istioctl` (1.26–1.27) doesn't have the `multicluster` subcommand.
The setup script uses manual YAML instead of `istioctl multicluster expose/link`.
The Solo Istio 1.30.0 binary (for the `istioctl multicluster check` verification step)
lives at a different GCS bucket key than the pre-req workshop's `e6283d67ad60`
(which only covers up to 1.29.x).

---

## Verifying the setup

After `setup.sh`:

```bash
export CLUSTER1=kind-cluster1
export CLUSTER2=kind-cluster2

# Istio ambient healthy on both clusters
kubectl get pods -n istio-system --context $CLUSTER1
kubectl get pods -n istio-system --context $CLUSTER2

# EAG controller running, GatewayClass accepted
kubectl get pods -n agentgateway-system --context $CLUSTER1
kubectl get gatewayclass enterprise-agentgateway-waypoint --context $CLUSTER1

# Peering succeeded
kubectl get gateway istio-remote-peer-cluster2 -n istio-gateways \
  --context $CLUSTER1 -o jsonpath='{.status.conditions}' | python3 -m json.tool \
  | grep -E '"type"|"status"'
```

Then follow the README to run through the five parts of the workshop.

---

## Version pins

| Component | Version |
|---|---|
| Solo Istio | `1.30.0-solo` |
| gloo-operator | `0.5.2` |
| Enterprise agentgateway | `2026.6.0-alpha-6cb5709` |
| MetalLB | `v0.14.9` |
| kind / Kubernetes | `1.35.0` (kind default) |

---

## Token exchange (Part 5) config

The EAG helm chart's `tokenExchange.*` values cover storage and maintenance only — the
validator schema isn't surfaced. The setup script ships a raw configSecret instead.

Source of truth: `ent-controller/internal/tokenexchange/sts/types.go` in the
`solo-io/agentgateway-enterprise` repo. Key facts:

1. The config is parsed by `sigs.k8s.io/yaml`, which converts YAML→JSON then
   case-insensitively matches Go field names. Fields have **no** json tags, so JSON keys
   like `subjectValidator` / `validatorType` map to Go fields `SubjectValidator` /
   `ValidatorType`.

2. The validator's discriminator field is **`validatorType`** (not `type`). Valid values:
   | Type     | Use case                          | Required sub-field         |
   |----------|-----------------------------------|----------------------------|
   | `remote` | Validate JWTs against a JWKS URL  | `remoteConfig.url`         |
   | `k8s`    | Validate K8s SA tokens via TokenReview | (uses in-cluster restConfig) |
   | `static` | Validate JWTs against an inline JWKS | `staticConfig` (jose.JSONWebKeySet) |

3. **Three** validators must be configured: `subjectValidator`, `actorValidator`,
   `apiValidator`. The workshop uses `remote` for the subject (mock-idp JWKS) and `k8s`
   for the other two.

4. Symptoms when this is misconfigured:
   - `issuer is required` → `issuer` field missing at top level
   - `unsupported validator type: ` (trailing empty) → wrong field name; controller saw
     no `validatorType` value. Often means you used `type` instead of `validatorType`.

5. `allowedSubjectClaims` lists the user-token claim names that survive the exchange and
   appear in the OBO token. Workshop needs `["role", "groups"]` so the user's `role`
   claim is available to the CEL ABAC policy as `jwt.role`.

The exact JSON shape (in `setup.sh` Phase 7):
```json
{
  "enabled": true,
  "issuer": "enterprise-agentgateway.agentgateway-system.svc.cluster.local:7777",
  "allowedSubjectClaims": ["role", "groups"],
  "subjectValidator": {
    "validatorType": "remote",
    "remoteConfig": { "url": "http://mock-idp.tokenexchange-test.svc.cluster.local/.well-known/jwks.json" }
  },
  "actorValidator": { "validatorType": "k8s" },
  "apiValidator":   { "validatorType": "k8s" },
  "storage": { "envelope": { "provider": "k8s-secret" } }
}
```
