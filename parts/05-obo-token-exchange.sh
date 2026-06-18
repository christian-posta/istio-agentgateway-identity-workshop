#!/usr/bin/env bash
# Part 5 — North-South on-behalf-of: agentgateway token exchange (RFC 8693).
#
# Token exchange itself is configured at infra time (setup.sh's eag-te-config
# secret + tokenExchange.enabled=true). This script:
#  1. Deploys the Part 5 infra (mock-idp, mock-upstream, tx-wp waypoint).
#  2. Runs setup-obo.sh to mint the demo IdP keypair and create the agents.
#  3. Walks through user-token mint → token exchange → upstream call.
#  4. Verifies may_act refuses an unauthorized agent acting on the user's behalf.
#  5. Applies the ABAC policy and exercises all four enforcement dimensions.

source "$(cd "$(dirname "$0")" && pwd)/_common.sh"

banner "Part 5 — On-behalf-of token exchange"

step "5.1 — Deploy Part 5 infra (mock-idp, mock-upstream, tx-wp waypoint)"
kubectl --context=${CLUSTER1} apply -f "${REPO_ROOT}/manifests/obo-infra.yaml" >/dev/null

step "5.2 — Run setup-obo.sh (mints IdP keypair, creates agents)"
"${REPO_ROOT}/scripts/setup-obo.sh" 2>&1 | tail -1

# Warm up: the STS lazily fetches mock-idp's JWKS on first use. Doing one throwaway
# exchange here primes the cache; without it, 5.4 races and fails with
# "JWKS not available for key: <kid>".
step "5.2.1 — Warming up STS JWKS cache (lazy fetch)"
warm_jwt=$("${REPO_ROOT}/scripts/mint-user-jwt.py" warmup@example.com system:serviceaccount:agents:agent-runtime cardholder-reader)
for i in $(seq 1 20); do
  resp=$(kubectl --context=${CLUSTER1} exec -n agents deploy/agent -- env UJWT="$warm_jwt" sh -c '
    curl -s http://enterprise-agentgateway.agentgateway-system.svc.cluster.local:7777/oauth2/token \
      --data-urlencode grant_type=urn:ietf:params:oauth:grant-type:token-exchange \
      --data-urlencode subject_token_type=urn:ietf:params:oauth:token-type:jwt \
      --data-urlencode actor_token_type=urn:ietf:params:oauth:token-type:jwt \
      --data-urlencode subject_token="$UJWT" \
      --data-urlencode actor_token="$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)"' 2>&1)
  if echo "$resp" | grep -q '"access_token"'; then
    echo "  JWKS warm after ${i} attempt(s)"
    break
  fi
  sleep 2
done

# exchange — mint a user JWT for $user with may_act=$may_act_sa, then exchange it
# from the $pod deployment (whose serviceAccountName is $actor_sa).
# Use this when you want may_act and actor to MATCH (the success path).
exchange() {
  local user="$1" role="$2" may_act_sa="$3" pod="$4"
  local ujwt
  ujwt=$("${REPO_ROOT}/scripts/mint-user-jwt.py" "$user" "system:serviceaccount:agents:${may_act_sa}" "$role")
  kubectl --context=${CLUSTER1} exec -n agents deploy/"$pod" -- env UJWT="$ujwt" sh -c '
    curl -s http://enterprise-agentgateway.agentgateway-system.svc.cluster.local:7777/oauth2/token \
      --data-urlencode grant_type=urn:ietf:params:oauth:grant-type:token-exchange \
      --data-urlencode subject_token_type=urn:ietf:params:oauth:token-type:jwt \
      --data-urlencode actor_token_type=urn:ietf:params:oauth:token-type:jwt \
      --data-urlencode subject_token="$UJWT" \
      --data-urlencode actor_token="$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)"'
}

step "5.3 — Mint user JWT for alice (may_act delegates to agent-runtime)"
"${REPO_ROOT}/scripts/mint-user-jwt.py" alice@example.com system:serviceaccount:agents:agent-runtime cardholder-reader > /tmp/user.jwt
udec=$("${REPO_ROOT}/scripts/jwt-decode.py" /tmp/user.jwt)
expect_contains "user JWT has role=cardholder-reader"      '"role": "cardholder-reader"' "$udec"
expect_contains "user JWT has may_act = agent-runtime SA"  '"sub": "system:serviceaccount:agents:agent-runtime"' "$udec"

step "5.4 — agent exchanges user JWT for an OBO token"
obo_json=$(exchange alice@example.com cardholder-reader agent-runtime agent)
obo_token=$(echo "$obo_json" | jq -r .access_token)
if [ -n "$obo_token" ] && [ "$obo_token" != "null" ]; then
  echo "$obo_token" > /tmp/obo.jwt
  odec=$("${REPO_ROOT}/scripts/jwt-decode.py" /tmp/obo.jwt)
  expect_contains "OBO sub = alice (the user)"        '"sub": "alice@example.com"' "$odec"
  expect_contains "OBO act.sub = agent-runtime"       '"sub": "system:serviceaccount:agents:agent-runtime"' "$odec"
  expect_contains "OBO role claim survived exchange"  '"role": "cardholder-reader"' "$odec"
else
  echo "  ${C_RED}✗${C_RESET} token exchange failed: $obo_json"
  FAIL_COUNT=$((FAIL_COUNT+1))
fi

step "5.5 — Use OBO token to call mock-upstream (require-obo policy)"
code=$(kubectl --context=${CLUSTER1} exec -n agents deploy/agent -- \
  curl -s -o /dev/null -w "%{http_code}" \
  -H "Authorization: Bearer $(cat /tmp/obo.jwt)" \
  http://mock-upstream.tokenexchange-test.svc.cluster.local/headers)
expect_eq "mock-upstream returns HTTP 200" "200" "$code"

step "5.6 — may_act refuses a different agent attempting to act for alice"
# IMPORTANT: alice's JWT still authorizes ONLY agent-runtime (may_act). The rogue pod
# (running as rogue-agent SA) tries to use it. STS validates may_act vs actor → refuses.
ujwt_alice=$("${REPO_ROOT}/scripts/mint-user-jwt.py" alice@example.com system:serviceaccount:agents:agent-runtime cardholder-reader)
rogue_resp=$(kubectl --context=${CLUSTER1} exec -n agents deploy/rogue -- env UJWT="$ujwt_alice" sh -c '
  curl -s http://enterprise-agentgateway.agentgateway-system.svc.cluster.local:7777/oauth2/token \
    --data-urlencode grant_type=urn:ietf:params:oauth:grant-type:token-exchange \
    --data-urlencode subject_token_type=urn:ietf:params:oauth:token-type:jwt \
    --data-urlencode actor_token_type=urn:ietf:params:oauth:token-type:jwt \
    --data-urlencode subject_token="$UJWT" \
    --data-urlencode actor_token="$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)"')
expect_contains "STS returned unauthorized_client error" 'unauthorized_client' "$rogue_resp"
expect_contains "error mentions actor != may_act"        'does not match may_act' "$rogue_resp"

step "5.7 — Apply combined ABAC policy (user · role · agent · jurisdiction)"
kubectl --context=${CLUSTER1} apply -f - >/dev/null <<'EOF'
apiVersion: enterpriseagentgateway.solo.io/v1alpha1
kind: EnterpriseAgentgatewayPolicy
metadata:
  name: obo-user-authz
  namespace: tokenexchange-test
spec:
  targetRefs:
  - group: gateway.networking.k8s.io
    kind: Gateway
    name: tx-wp
  traffic:
    authorization:
      action: Allow
      policy:
        matchExpressions:
        - >-
          jwt.sub.endsWith("@example.com") &&
          jwt.role == "cardholder-reader" &&
          jwt.act.sub == "system:serviceaccount:agents:agent-runtime" &&
          source.claims["solo.io.security-claims.jurisdiction"] == "eu"
EOF
echo "  policy applied; waiting 5s for propagation..."
sleep 5

# call_with_obo — full path: mint user JWT (may_act=$may_act_sa), exchange from $pod,
# call mock-upstream with the result. Mirrors the README's `try` helper exactly.
call_with_obo() {
  local user="$1" role="$2" may_act_sa="$3" pod="$4"
  local obo_json obo
  obo_json=$(exchange "$user" "$role" "$may_act_sa" "$pod")
  obo=$(echo "$obo_json" | jq -r .access_token)
  if [ -z "$obo" ] || [ "$obo" = "null" ]; then echo "no-token"; return; fi
  kubectl --context=${CLUSTER1} exec -n agents deploy/agent -- \
    curl -s -o /dev/null -w "%{http_code}" \
    -H "Authorization: Bearer $obo" \
    http://mock-upstream.tokenexchange-test.svc.cluster.local/headers
}

step "5.8 — Verify ABAC enforcement on each dimension"
# Mirrors the four `try` cases from the README. The last case sets may_act=rogue-agent
# so the exchange succeeds; the upstream then rejects because jwt.act.sub != agent-runtime.
expect_eq "alice + cardholder-reader + agent-runtime → 200"     "200" "$(call_with_obo alice@example.com   cardholder-reader agent-runtime agent)"
expect_eq "mallory@evil.io  (wrong jwt.sub domain)  → 403"      "403" "$(call_with_obo mallory@evil.io     cardholder-reader agent-runtime agent)"
expect_eq "alice + analyst (wrong jwt.role)         → 403"      "403" "$(call_with_obo alice@example.com   analyst           agent-runtime agent)"
expect_eq "rogue-agent acting (wrong jwt.act.sub)   → 403"      "403" "$(call_with_obo alice@example.com   cardholder-reader rogue-agent   rogue)"

summarize
