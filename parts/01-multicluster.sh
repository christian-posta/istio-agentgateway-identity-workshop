#!/usr/bin/env bash
# Part 1 — Mesh & multi-cluster, by labeling.
#
# Deploys cardholder on cluster1 + tenant clients on cluster2, then makes
# cardholder a global cross-cluster service via a single label. Verifies all
# three tenants reach cardholder over mTLS, cross-cluster and cross-trust-domain.

source "$(cd "$(dirname "$0")" && pwd)/_common.sh"

banner "Part 1 — Mesh & multi-cluster by labeling"

step "1.1 — Deploy cardholder (cluster1) and tenant clients (cluster2)"
kubectl --context=${CLUSTER1} create ns tenant-payments --dry-run=client -o yaml | kubectl --context=${CLUSTER1} apply -f - >/dev/null
kubectl --context=${CLUSTER1} apply -f "${REPO_ROOT}/manifests/cardholder.yaml" >/dev/null

# Add cardholder's namespace to the ambient mesh (it earns a SPIFFE identity)
kubectl --context=${CLUSTER1} label ns tenant-payments istio.io/dataplane-mode=ambient --overwrite >/dev/null

# Tenant clients live on cluster2 (different trust domain)
kubectl --context=${CLUSTER2} apply -f "${REPO_ROOT}/manifests/tenant-clients.yaml" >/dev/null

# Wait for everything to roll out
kubectl --context=${CLUSTER1} rollout status deploy/cardholder -n tenant-payments --timeout=120s >/dev/null
kubectl --context=${CLUSTER2} rollout status deploy/payments-api-eu -n tenant-payments --timeout=120s >/dev/null
kubectl --context=${CLUSTER2} rollout status deploy/payments-api-hk -n tenant-payments --timeout=120s >/dev/null
kubectl --context=${CLUSTER2} rollout status deploy/reporting       -n tenant-analytics --timeout=120s >/dev/null
echo "  workloads ready"

step "1.2 — Verify cardholder has a SPIFFE identity"
svid_out=$("${REPO_ROOT}/scripts/show-svid.sh" ${CLUSTER1} tenant-payments cardholder 2>&1)
expect_contains "SPIFFE id is cluster1.local" \
  "spiffe://cluster1.local/ns/tenant-payments/sa/cardholder" "$svid_out"

step "1.3 — Verify cardholder is NOT reachable cross-cluster yet"
read eu hk rep <<< "$(tenant_to_cardholder_codes)"
expect_eq "payments-api-eu unreachable" "000" "$eu"
expect_eq "payments-api-hk unreachable" "000" "$hk"
expect_eq "reporting unreachable"       "000" "$rep"

step "1.4 — Label cardholder as a global cross-cluster service"
# Apply BOTH labels: solo.io/service-scope is the Solo-native label; istio.io/global
# is what istiod's serviceScopeConfigs actually selects on.
kubectl --context=${CLUSTER1} label svc cardholder -n tenant-payments \
  solo.io/service-scope=global istio.io/global=true --overwrite >/dev/null
echo "  cardholder now global; waiting 10s for propagation..."
sleep 10

step "1.5 — Verify cardholder is reachable from all three tenants"
read eu hk rep <<< "$(tenant_to_cardholder_codes)"
expect_eq "payments-api-eu  -> cardholder" "200" "$eu"
expect_eq "payments-api-hk  -> cardholder" "200" "$hk"
expect_eq "reporting        -> cardholder" "200" "$rep"

summarize
