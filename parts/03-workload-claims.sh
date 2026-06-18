#!/usr/bin/env bash
# Part 3 — Workload-identity claims in the SVID.
#
# Annotate each tenant pod with `solo.io.security-claims/jurisdiction`. istiod
# attests these claims and embeds them in the workload's SVID. The two
# payments-api pods get the SAME service account but DIFFERENT claims.
# Replace the SPIFFE-id-based policy with one matching attested claims.

source "$(cd "$(dirname "$0")" && pwd)/_common.sh"

banner "Part 3 — Workload-identity claims in the SVID"

step "3.1 — Annotate each tenant with its jurisdiction"
kubectl --context=${CLUSTER2} -n tenant-payments  patch deploy payments-api-eu --type=merge \
  -p '{"spec":{"template":{"metadata":{"annotations":{"solo.io.security-claims/jurisdiction":"eu"}}}}}' >/dev/null
kubectl --context=${CLUSTER2} -n tenant-payments  patch deploy payments-api-hk --type=merge \
  -p '{"spec":{"template":{"metadata":{"annotations":{"solo.io.security-claims/jurisdiction":"hk"}}}}}' >/dev/null
kubectl --context=${CLUSTER2} -n tenant-analytics patch deploy reporting       --type=merge \
  -p '{"spec":{"template":{"metadata":{"annotations":{"solo.io.security-claims/jurisdiction":"eu"}}}}}' >/dev/null

kubectl --context=${CLUSTER2} rollout status deploy/payments-api-eu -n tenant-payments  --timeout=120s >/dev/null
kubectl --context=${CLUSTER2} rollout status deploy/payments-api-hk -n tenant-payments  --timeout=120s >/dev/null
kubectl --context=${CLUSTER2} rollout status deploy/reporting       -n tenant-analytics --timeout=120s >/dev/null
echo "  jurisdictions: payments-api-eu=eu, payments-api-hk=hk, reporting=eu"

step "3.2 — Verify SVIDs carry attested claims"
eu_svid=$("${REPO_ROOT}/scripts/show-svid.sh" ${CLUSTER2} tenant-payments  payments-api-eu)
hk_svid=$("${REPO_ROOT}/scripts/show-svid.sh" ${CLUSTER2} tenant-payments  payments-api-hk)
rep_svid=$("${REPO_ROOT}/scripts/show-svid.sh" ${CLUSTER2} tenant-analytics reporting)
expect_contains "payments-api-eu claims include jurisdiction=eu" '"jurisdiction": "eu"'  "$eu_svid"
expect_contains "payments-api-hk claims include jurisdiction=hk" '"jurisdiction": "hk"'  "$hk_svid"
expect_contains "reporting claims include zone=general"          '"zone": "general"'     "$rep_svid"

step "3.3 — Apply claim-based AuthorizationPolicy (zone=PCI-DSS AND jurisdiction=eu)"
kubectl --context=${CLUSTER1} apply -f - <<'EOF' >/dev/null
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata:
  name: cardholder-allow
  namespace: tenant-payments
spec:
  selector:
    matchLabels:
      app: cardholder
  action: ALLOW
  rules:
  - when:
    - key: "source.claims['solo.io.security-claims.zone']"
      values:
      - PCI-DSS
    - key: "source.claims['solo.io.security-claims.jurisdiction']"
      values:
      - eu
EOF
echo "  policy applied; waiting 5s for propagation..."
sleep 5

step "3.4 — Verify only EU jurisdiction reaches cardholder"
read eu hk rep <<< "$(tenant_to_cardholder_codes)"
expect_eq "payments-api-eu  -> ALLOW (zone=PCI-DSS, juris=eu)" "200" "$eu"
expect_eq "payments-api-hk  -> DENY  (juris=hk)"               "000" "$hk"
expect_eq "reporting        -> DENY  (zone=general)"           "000" "$rep"

summarize
