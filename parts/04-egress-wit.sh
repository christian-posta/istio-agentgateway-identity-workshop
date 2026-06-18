#!/usr/bin/env bash
# Part 4 — Identity beyond the mesh: WIT delegation on egress.
#
# Deploys an egress gateway (an EAG waypoint) + a meshed trading-app, then
# configures a ServiceEntry for postman-echo.com with a SourceDelegation
# policy. The agentgateway injects a Workload-Identity-Token header on
# egress; the echo service reflects it back.

source "$(cd "$(dirname "$0")" && pwd)/_common.sh"

banner "Part 4 — Identity beyond the mesh (WIT on egress)"

step "4.1 — Deploy egress gateway + meshed trading-app"
kubectl --context=${CLUSTER1} apply -f "${REPO_ROOT}/manifests/egress.yaml" >/dev/null
kubectl --context=${CLUSTER1} rollout status deploy/trading-app -n egress-client --timeout=120s >/dev/null
# Wait for the egress-gateway Pod (managed by EAG controller via the Gateway resource)
echo "  waiting for egress-gateway Deployment..."
for _ in $(seq 1 30); do
  if kubectl --context=${CLUSTER1} get deploy egress-gateway -n common-infrastructure >/dev/null 2>&1; then break; fi
  sleep 2
done
kubectl --context=${CLUSTER1} rollout status deploy/egress-gateway -n common-infrastructure --timeout=120s >/dev/null
echo "  ready"

step "4.2 — Apply ServiceEntry + tunnel + WIT SourceDelegation policy"
kubectl --context=${CLUSTER1} apply -f - >/dev/null <<'EOF'
apiVersion: networking.istio.io/v1
kind: ServiceEntry
metadata:
  name: postman-echo
  namespace: common-infrastructure
  labels:
    istio.io/use-waypoint: egress-gateway
spec:
  hosts:
  - postman-echo.com
  location: MESH_EXTERNAL
  resolution: DNS
  ports:
  - { number: 80,  name: http,  protocol: HTTP, targetPort: 443 }
  - { number: 443, name: https, protocol: TLS }
---
apiVersion: enterpriseagentgateway.solo.io/v1alpha1
kind: EnterpriseAgentgatewayPolicy
metadata:
  name: postman-echo-tunnel
  namespace: common-infrastructure
spec:
  targetRefs:
  - { name: postman-echo, kind: ServiceEntry, group: networking.istio.io }
  backend:
    tls: { sni: postman-echo.com }
---
apiVersion: enterpriseagentgateway.solo.io/v1alpha1
kind: EnterpriseAgentgatewayPolicy
metadata:
  name: postman-echo-wit
  namespace: common-infrastructure
spec:
  targetRefs:
  - { name: postman-echo, kind: ServiceEntry, group: networking.istio.io }
  backend:
    workloadIdentity:
      mode: SourceDelegation
EOF
echo "  policies applied; waiting 5s for propagation..."
sleep 5

step "4.3 — Call postman-echo.com through the egress gateway"
resp=$(kubectl --context=${CLUSTER1} exec -n egress-client deploy/trading-app -- \
  curl -sS --max-time 25 http://postman-echo.com/get 2>&1)

# Extract the WIT header echoed back
wit=$(echo "$resp" | jq -r '.headers["workload-identity-token"] // empty' 2>/dev/null)

if [ -n "$wit" ] && [ "$wit" != "null" ]; then
  echo "  ${C_GREEN}✓${C_RESET} workload-identity-token header present on egress"
  PASS_COUNT=$((PASS_COUNT+1))
  echo "$wit" > /tmp/wit.jwt
else
  echo "  ${C_RED}✗${C_RESET} WIT header missing from echo response"
  echo "    response (first 300 chars): $(echo "$resp" | head -c 300)"
  FAIL_COUNT=$((FAIL_COUNT+1))
fi

step "4.4 — Decode the WIT and verify it carries the attested claims"
if [ -f /tmp/wit.jwt ]; then
  decoded=$("${REPO_ROOT}/scripts/jwt-decode.py" /tmp/wit.jwt 2>&1)
  expect_contains "WIT typ is wit+jwt"                     '"typ": "wit+jwt"'    "$decoded"
  expect_contains "WIT sub points to trading-app"          'spiffe://cluster1.local/ns/egress-client/sa/trading-app' "$decoded"
  expect_contains "WIT carries zone=PCI-DSS claim"         '"zone": "PCI-DSS"'   "$decoded"
  expect_contains "WIT carries jurisdiction=eu claim"      '"jurisdiction": "eu"' "$decoded"
fi

summarize
