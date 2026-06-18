#!/usr/bin/env bash
# Part 2 — Identity-based authorization (and its limit).
#
# Applies an AuthorizationPolicy that only allows callers whose SPIFFE identity
# matches `cluster2.local/ns/tenant-payments/sa/payments-api`. reporting (different
# SA → different SPIFFE id) is denied. But payments-api-eu and payments-api-hk share
# the same SA, so the policy cannot distinguish them — that's Part 3's job.

source "$(cd "$(dirname "$0")" && pwd)/_common.sh"

banner "Part 2 — Identity-based authorization (and its limit)"

step "2.1 — Apply AuthorizationPolicy allowing only payments-api SPIFFE identity"
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
  - from:
    - source:
        principals:
        - cluster2.local/ns/tenant-payments/sa/payments-api
EOF
echo "  policy applied; waiting 5s for propagation..."
sleep 5

step "2.2 — Verify reporting is denied; payments-api (both pods) still allowed"
read eu hk rep <<< "$(tenant_to_cardholder_codes)"
expect_eq "payments-api-eu  -> ALLOW"               "200" "$eu"
expect_eq "payments-api-hk  -> ALLOW (limit shown)" "200" "$hk"
expect_eq "reporting        -> DENY"                "000" "$rep"

echo
echo "  Note: payments-api-eu and payments-api-hk share the same SA → same SPIFFE id."
echo "  Part 3 fixes this by attesting per-workload claims."

summarize
