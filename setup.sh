#!/usr/bin/env bash
# setup.sh — Provision the two-cluster ambient mesh environment for the
#            Workload & Agent Identity workshop (Solo Istio 1.30 + agentgateway).
#
# Prerequisites:
#   kind, docker, helm, kubectl     — in PATH
#   gcloud auth login               — authenticated to pull EAG images
#   GLOO_MESH_LICENSE               — exported, or sourced via ~/bin/gloo-mesh-license-env
#
# Assumptions:
#   ambient-multicluster-workshop/  is a sibling directory of this repo
#   (provides certs/cluster{1,2}/ for the shared root CA)
#
# Usage:
#   source ~/bin/gloo-mesh-license-env
#   ./setup.sh
#
# Time: ~5–7 min on a fast machine with warm Docker image cache.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Configuration ─────────────────────────────────────────────────────────────
CLUSTER1=kind-cluster1
CLUSTER2=kind-cluster2

GLOO_OPERATOR_VERSION="0.5.2"
ISTIO_VERSION="1.30.0"
METALLB_VERSION="v0.14.9"

EAG_VERSION="2026.6.0-alpha-6cb5709"
EAG_REGISTRY="us-central1-docker.pkg.dev/developers-369321/enterprise-agentgateway-public-nonprod"

CERTS_DIR="${SCRIPT_DIR}/../ambient-multicluster-workshop/certs"

# ── License check ─────────────────────────────────────────────────────────────
if [[ -z "${GLOO_MESH_LICENSE:-}" ]]; then
  [[ -f "$HOME/bin/gloo-mesh-license-env" ]] && source "$HOME/bin/gloo-mesh-license-env"
fi
if [[ -z "${GLOO_MESH_LICENSE:-}" ]]; then
  echo "ERROR: GLOO_MESH_LICENSE is not set." >&2
  echo "       Run: source ~/bin/gloo-mesh-license-env" >&2
  exit 1
fi

# ── Helpers ───────────────────────────────────────────────────────────────────
phase() {
  echo
  echo "══════════════════════════════════════════════════════════"
  printf "  Phase %s\n" "$*"
  echo "══════════════════════════════════════════════════════════"
}
log() { echo "  ▸ $*"; }

wait_for_smc() {
  local ctx="$1"
  log "Waiting for ServiceMeshController on ${ctx}..."
  until kubectl get servicemeshcontroller istio --context="${ctx}" \
      -o jsonpath='{.status.phase}' 2>/dev/null | grep -q "SUCCEEDED"; do
    sleep 5
  done
  log "${ctx}: Istio SUCCEEDED"
}

# ── Phase 1: kind clusters ────────────────────────────────────────────────────
phase "1/8 — kind clusters"

pids=()
for name in cluster1 cluster2; do
  if kind get clusters 2>/dev/null | grep -q "^${name}$"; then
    log "kind cluster '${name}' already exists — skipping"
  else
    kind create cluster --name "${name}" &
    pids+=($!)
  fi
done
for pid in "${pids[@]:-}"; do wait "$pid"; done
log "kind clusters ready"

# ── Phase 2: MetalLB ──────────────────────────────────────────────────────────
phase "2/8 — MetalLB (LoadBalancer support for east-west gateways)"

# kind always uses 172.18.0.0/16; detect the actual prefix in case it differs
KIND_PREFIX=$(docker network inspect kind 2>/dev/null \
  | python3 -c "import sys,json; c=json.load(sys.stdin); \
    s=c[0]['IPAM']['Config'][0]['Subnet']; print('.'.join(s.split('.')[:2]))" \
  2>/dev/null || echo "172.18")
C1_METALLB="${KIND_PREFIX}.255.200-${KIND_PREFIX}.255.220"
C2_METALLB="${KIND_PREFIX}.255.221-${KIND_PREFIX}.255.240"
log "MetalLB pools: cluster1=${C1_METALLB}  cluster2=${C2_METALLB}"

kubectl apply --context ${CLUSTER1} \
  -f "https://raw.githubusercontent.com/metallb/metallb/${METALLB_VERSION}/config/manifests/metallb-native.yaml" &
kubectl apply --context ${CLUSTER2} \
  -f "https://raw.githubusercontent.com/metallb/metallb/${METALLB_VERSION}/config/manifests/metallb-native.yaml" &
wait

kubectl wait --context ${CLUSTER1} -n metallb-system --for=condition=ready \
  pod -l app=metallb,component=controller --timeout=120s &
kubectl wait --context ${CLUSTER2} -n metallb-system --for=condition=ready \
  pod -l app=metallb,component=controller --timeout=120s &
wait

for entry in "${CLUSTER1}:${C1_METALLB}" "${CLUSTER2}:${C2_METALLB}"; do
  ctx="${entry%%:*}"; range="${entry#*:}"
  kubectl apply --context "${ctx}" -f - <<EOF
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata: { name: kind-pool, namespace: metallb-system }
spec:
  addresses: ["${range}"]
---
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata: { name: kind-l2, namespace: metallb-system }
EOF
done
log "MetalLB configured"

# ── Phase 3: Shared root CA ───────────────────────────────────────────────────
phase "3/8 — Shared intermediate CA (same root, separate trust domains)"

for ctx in ${CLUSTER1} ${CLUSTER2}; do
  for ns in istio-system istio-gateways; do
    kubectl --context="${ctx}" create ns "${ns}" --dry-run=client -o yaml \
      | kubectl --context="${ctx}" apply -f -
  done
done

for n in 1 2; do
  kubectl --context="kind-cluster${n}" create secret generic cacerts \
    -n istio-system \
    --from-file="${CERTS_DIR}/cluster${n}/ca-cert.pem" \
    --from-file="${CERTS_DIR}/cluster${n}/ca-key.pem" \
    --from-file="${CERTS_DIR}/cluster${n}/root-cert.pem" \
    --from-file="${CERTS_DIR}/cluster${n}/cert-chain.pem" \
    --dry-run=client -o yaml | kubectl --context="kind-cluster${n}" apply -f -
done
log "Shared root CA configured"

# ── Phase 4: Solo Istio via gloo-operator ─────────────────────────────────────
phase "4/8 — gloo-operator + Solo Istio ${ISTIO_VERSION} (ambient)"

for ctx in ${CLUSTER1} ${CLUSTER2}; do
  helm upgrade -i --kube-context="${ctx}" gloo-operator \
    oci://us-docker.pkg.dev/solo-public/gloo-operator-helm/gloo-operator \
    --version "${GLOO_OPERATOR_VERSION}" \
    -n gloo-system --create-namespace \
    --set manager.env.SOLO_ISTIO_LICENSE_KEY="${GLOO_MESH_LICENSE}" \
    --set manager.image.repository=us-docker.pkg.dev/solo-public/gloo-operator/gloo-operator \
    &
done
wait

kubectl wait --context ${CLUSTER1} -n gloo-system --for=condition=ready \
  pod -l app.kubernetes.io/name=gloo-operator --timeout=120s &
kubectl wait --context ${CLUSTER2} -n gloo-system --for=condition=ready \
  pod -l app.kubernetes.io/name=gloo-operator --timeout=120s &
wait

# ServiceMeshController installs Solo Istio in ambient mode with per-cluster trust domains
kubectl --context=${CLUSTER1} apply -f - <<EOF
apiVersion: operator.gloo.solo.io/v1
kind: ServiceMeshController
metadata: { name: istio }
spec:
  version: "${ISTIO_VERSION}"
  cluster: cluster1
  network: cluster1
  trustDomain: cluster1.local
  dataplaneMode: Ambient
EOF

kubectl --context=${CLUSTER2} apply -f - <<EOF
apiVersion: operator.gloo.solo.io/v1
kind: ServiceMeshController
metadata: { name: istio }
spec:
  version: "${ISTIO_VERSION}"
  cluster: cluster2
  network: cluster2
  trustDomain: cluster2.local
  dataplaneMode: Ambient
EOF

wait_for_smc ${CLUSTER1} &
wait_for_smc ${CLUSTER2} &
wait

# Enable workload claims on istiod and ztunnel (required for Parts 3–5)
# This allows pod annotations (solo.io.security-claims/*) to be attested into the SVID.
for ctx in ${CLUSTER1} ${CLUSTER2}; do
  kubectl patch deploy istiod-gloo -n istio-system --context "${ctx}" \
    --type=json -p='[{"op":"add","path":"/spec/template/spec/containers/0/env/-",
      "value":{"name":"ENABLE_WORKLOAD_CLAIMS","value":"true"}}]'
  kubectl patch ds ztunnel -n istio-system --context "${ctx}" \
    --type=json -p='[{"op":"add","path":"/spec/template/spec/containers/0/env/-",
      "value":{"name":"ENABLE_WORKLOAD_CLAIMS","value":"true"}}]'
done

kubectl rollout status deploy/istiod-gloo -n istio-system --context ${CLUSTER1} --timeout=120s &
kubectl rollout status deploy/istiod-gloo -n istio-system --context ${CLUSTER2} --timeout=120s &
kubectl rollout status ds/ztunnel    -n istio-system --context ${CLUSTER1} --timeout=120s &
kubectl rollout status ds/ztunnel    -n istio-system --context ${CLUSTER2} --timeout=120s &
wait
log "Solo Istio ${ISTIO_VERSION} ready on both clusters with workload claims enabled"

# ── Phase 5: East-west gateways ───────────────────────────────────────────────
phase "5/8 — East-west gateways"

kubectl apply --context ${CLUSTER1} -f - <<'EOF'
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: istio-eastwest
  namespace: istio-gateways
  labels:
    istio.io/expose-istiod: "15012"
    topology.istio.io/network: cluster1
spec:
  gatewayClassName: istio-eastwest
  listeners:
  - { name: cross-network, port: 15008, protocol: HBONE, tls: { mode: Passthrough } }
  - { name: xds-tls,       port: 15012, protocol: TLS,   tls: { mode: Passthrough } }
EOF

kubectl apply --context ${CLUSTER2} -f - <<'EOF'
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: istio-eastwest
  namespace: istio-gateways
  labels:
    istio.io/expose-istiod: "15012"
    topology.istio.io/network: cluster2
spec:
  gatewayClassName: istio-eastwest
  listeners:
  - { name: cross-network, port: 15008, protocol: HBONE, tls: { mode: Passthrough } }
  - { name: xds-tls,       port: 15012, protocol: TLS,   tls: { mode: Passthrough } }
EOF

log "Waiting for east-west gateway LoadBalancer IPs..."
until kubectl get svc -n istio-gateways --context ${CLUSTER1} \
    -o jsonpath='{.items[0].status.loadBalancer.ingress[0].ip}' 2>/dev/null \
    | grep -q '[0-9]'; do sleep 3; done
until kubectl get svc -n istio-gateways --context ${CLUSTER2} \
    -o jsonpath='{.items[0].status.loadBalancer.ingress[0].ip}' 2>/dev/null \
    | grep -q '[0-9]'; do sleep 3; done

C1_EW=$(kubectl get svc -n istio-gateways --context ${CLUSTER1} \
  -o jsonpath='{.items[0].status.loadBalancer.ingress[0].ip}')
C2_EW=$(kubectl get svc -n istio-gateways --context ${CLUSTER2} \
  -o jsonpath='{.items[0].status.loadBalancer.ingress[0].ip}')
log "cluster1 east-west: ${C1_EW}   cluster2 east-west: ${C2_EW}"

# IMPORTANT: gateway.istio.io/trust-domain MUST include ".local"
# Using "cluster1" instead of "cluster1.local" causes a SPIFFE SAN mismatch:
#   "expected spiffe://cluster1/... got spiffe://cluster1.local/..."
kubectl apply --context ${CLUSTER1} -f - <<EOF
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: istio-remote-peer-cluster2
  namespace: istio-gateways
  annotations:
    gateway.istio.io/service-account: istio-eastwest
    gateway.istio.io/trust-domain: cluster2.local
  labels:
    topology.istio.io/network: cluster2
spec:
  addresses: [{ type: IPAddress, value: "${C2_EW}" }]
  gatewayClassName: istio-remote
  listeners:
  - { name: cross-network, port: 15008, protocol: HBONE, tls: { mode: Passthrough } }
  - { name: xds-tls,       port: 15012, protocol: TLS,   tls: { mode: Passthrough } }
EOF

kubectl apply --context ${CLUSTER2} -f - <<EOF
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: istio-remote-peer-cluster1
  namespace: istio-gateways
  annotations:
    gateway.istio.io/service-account: istio-eastwest
    gateway.istio.io/trust-domain: cluster1.local
  labels:
    topology.istio.io/network: cluster1
spec:
  addresses: [{ type: IPAddress, value: "${C1_EW}" }]
  gatewayClassName: istio-remote
  listeners:
  - { name: cross-network, port: 15008, protocol: HBONE, tls: { mode: Passthrough } }
  - { name: xds-tls,       port: 15012, protocol: TLS,   tls: { mode: Passthrough } }
EOF
log "Remote peer gateways configured"

# ── Phase 6: Multicluster workload endpoint discovery ─────────────────────────
phase "6/8 — Multicluster workload discovery (istio.io/multiCluster secrets)"

# NOTE: We use istio.io/multiCluster-typed secrets, NOT the file-based istio-kubeconfig
# volume mount. The KUBECONFIG env var in istiod points to an optional volume; when that
# secret is absent, istiod uses its in-cluster SA for local access and these secrets for
# remote access. Mounting a kubeconfig file instead overrides ALL cluster access and
# breaks istiod's ability to reach its own local API server.

# Create the service account + RBAC on each cluster (used by the OTHER cluster's istiod)
for ctx in ${CLUSTER1} ${CLUSTER2}; do
  kubectl apply --context "${ctx}" -f - <<'RBAC'
apiVersion: v1
kind: ServiceAccount
metadata:
  name: istio-remote-secret-sa
  namespace: istio-system
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: istio-remote
rules:
- apiGroups: [""]
  resources: ["nodes", "pods", "services", "endpoints", "namespaces"]
  verbs: ["get", "watch", "list"]
- apiGroups: ["discovery.k8s.io"]
  resources: ["endpointslices"]
  verbs: ["get", "watch", "list"]
- apiGroups: ["networking.istio.io", "security.istio.io", "gateway.networking.k8s.io"]
  resources: ["*"]
  verbs: ["get", "watch", "list"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: istio-remote-secret-sa
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: istio-remote
subjects:
- kind: ServiceAccount
  name: istio-remote-secret-sa
  namespace: istio-system
RBAC
done

# Build and apply istio.io/multiCluster secrets:
#   cluster1 gets a secret that lets it watch cluster2's workloads
#   cluster2 gets a secret that lets it watch cluster1's workloads
for remote_ctx in ${CLUSTER2} ${CLUSTER1}; do
  if [[ "$remote_ctx" == "$CLUSTER2" ]]; then local_ctx=${CLUSTER1}; else local_ctx=${CLUSTER2}; fi
  remote_name="${remote_ctx#kind-}"   # kind-cluster2 → cluster2

  # --minify ensures we get exactly the right cluster's CA (global kubeconfig has many entries)
  REMOTE_CA=$(kubectl config view --context "${remote_ctx}" --raw --minify \
    -o jsonpath='{.clusters[0].cluster.certificate-authority-data}')
  REMOTE_IP=$(docker inspect "${remote_name}-control-plane" \
    --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}')
  # Long-lived token — acceptable for a local workshop; rotate for anything beyond that
  REMOTE_TOKEN=$(kubectl create token istio-remote-secret-sa \
    -n istio-system --context "${remote_ctx}" --duration=87600h)

  KUBECONFIG_YAML=$(cat <<KCFG
apiVersion: v1
kind: Config
clusters:
- name: ${remote_name}
  cluster:
    server: https://${REMOTE_IP}:6443
    certificate-authority-data: ${REMOTE_CA}
contexts:
- name: ${remote_name}
  context: { cluster: ${remote_name}, user: istio-remote-secret-sa }
current-context: ${remote_name}
users:
- name: istio-remote-secret-sa
  user:
    token: ${REMOTE_TOKEN}
KCFG
)

  kubectl apply --context "${local_ctx}" -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: istio-remote-secret-${remote_name}
  namespace: istio-system
  labels:
    istio.io/owned-by: istio-multicluster
type: istio.io/multiCluster
data:
  ${remote_name}: $(echo "${KUBECONFIG_YAML}" | base64 | tr -d '\n')
EOF
  log "  ${local_ctx} will watch ${remote_name} workloads"
done

# Restart istiod so the new secrets are loaded immediately
kubectl rollout restart deploy/istiod-gloo -n istio-system --context ${CLUSTER1} &
kubectl rollout restart deploy/istiod-gloo -n istio-system --context ${CLUSTER2} &
wait
kubectl rollout status deploy/istiod-gloo -n istio-system --context ${CLUSTER1} --timeout=120s &
kubectl rollout status deploy/istiod-gloo -n istio-system --context ${CLUSTER2} --timeout=120s &
wait
log "Multicluster workload discovery configured"

# ── Phase 7: Enterprise agentgateway ─────────────────────────────────────────
phase "7/8 — Enterprise agentgateway ${EAG_VERSION} (cluster1 only)"

# CRDs are in a separate chart — install first
helm upgrade -i enterprise-agentgateway-crds \
  oci://${EAG_REGISTRY}/charts/enterprise-agentgateway-crds \
  --version "${EAG_VERSION}" \
  --namespace agentgateway-system --create-namespace \
  --kube-context=${CLUSTER1}

# Token exchange config for Part 5 (OBO / RFC 8693). The chart's tokenExchange.* values
# don't surface the validator schema, so we ship a configSecret with the full JSON.
# Field names match Go struct fields case-insensitively (sigs.k8s.io/yaml semantics):
#   subjectValidator → validates the user's JWT against mock-idp's JWKS (validatorType: remote)
#   actorValidator   → validates the agent's K8s SA token via TokenReview (validatorType: k8s)
#   apiValidator     → required for STS endpoint auth (also k8s)
# Subject token claims listed in allowedSubjectClaims survive the exchange into the OBO token.
kubectl create secret generic eag-te-config \
  --context ${CLUSTER1} -n agentgateway-system \
  --from-literal=config='{
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
  }' \
  --dry-run=client -o yaml | kubectl apply --context ${CLUSTER1} -f -

# The GLOO_MESH_LICENSE key causes a license warning (it's a gloo-mesh product key)
# but the controller still starts and the GatewayClass becomes Accepted.
#
# istio.* values are REQUIRED for Part 4 (egress WIT). Without them, the controller
# generates gateway pods with TRUST_DOMAIN=cluster.local and CA_ADDRESS=istiod.istio-system.svc:15012,
# neither of which match our setup. The pods then fail to fetch their SVID and reset all connections.
helm upgrade -i enterprise-agentgateway \
  oci://${EAG_REGISTRY}/charts/enterprise-agentgateway \
  --version "${EAG_VERSION}" \
  --namespace agentgateway-system \
  --kube-context=${CLUSTER1} \
  --set licensing.licenseKey="${GLOO_MESH_LICENSE}" \
  --set tokenExchange.enabled=true \
  --set tokenExchange.configSecret.name=eag-te-config \
  --set istio.autoEnabled=true \
  --set istio.revision=gloo \
  --set istio.clusterId=cluster1 \
  --set istio.network=cluster1 \
  --set istio.caAddress="https://istiod-gloo.istio-system.svc:15012"

kubectl wait --context ${CLUSTER1} -n agentgateway-system \
  --for=condition=ready pod -l agentgateway=agentgateway --timeout=120s
log "Enterprise agentgateway ready"

GC_STATUS=$(kubectl get gatewayclass enterprise-agentgateway-waypoint \
  --context ${CLUSTER1} \
  -o jsonpath='{.status.conditions[?(@.type=="Accepted")].status}' 2>/dev/null || echo "Unknown")
log "GatewayClass enterprise-agentgateway-waypoint: Accepted=${GC_STATUS}"

# ── Phase 8: Summary ──────────────────────────────────────────────────────────
phase "8/8 — Summary"

for ctx in ${CLUSTER1} ${CLUSTER2}; do
  echo "  ${ctx} istio-system pods:"
  kubectl get pods -n istio-system --context "${ctx}" --no-headers 2>/dev/null \
    | awk '{printf "    %-52s %s/%s\n", $1, $2, $3}'
done

cat <<DONE

══════════════════════════════════════════════════════════
  Setup complete!

  Export these before running workshop scripts:

    export CLUSTER1=kind-cluster1
    export CLUSTER2=kind-cluster2

  Then work through the README in this directory.
  The pre-req (Parts 1–3) is already verified to work.
══════════════════════════════════════════════════════════
DONE
