# Shared helpers for part scripts. Source this; do not run directly.
set -uo pipefail

: "${CLUSTER1:?CLUSTER1 must be set, e.g. export CLUSTER1=kind-cluster1}"
: "${CLUSTER2:?CLUSTER2 must be set, e.g. export CLUSTER2=kind-cluster2}"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Colors (no-op if not a TTY)
if [ -t 1 ]; then
  C_GREEN=$'\033[32m'; C_RED=$'\033[31m'; C_YELLOW=$'\033[33m'; C_BLUE=$'\033[34m'; C_RESET=$'\033[0m'
else
  C_GREEN=; C_RED=; C_YELLOW=; C_BLUE=; C_RESET=
fi

PASS_COUNT=0
FAIL_COUNT=0

banner() {
  echo
  echo "${C_BLUE}════════════════════════════════════════════════════════════${C_RESET}"
  echo "${C_BLUE}  $*${C_RESET}"
  echo "${C_BLUE}════════════════════════════════════════════════════════════${C_RESET}"
}

step()  { echo; echo "${C_YELLOW}▸ $*${C_RESET}"; }

# expect_eq <label> <expected> <actual>
expect_eq() {
  local label="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    echo "  ${C_GREEN}✓${C_RESET} $label (got $actual)"
    PASS_COUNT=$((PASS_COUNT+1))
  else
    echo "  ${C_RED}✗${C_RESET} $label (expected $expected, got $actual)"
    FAIL_COUNT=$((FAIL_COUNT+1))
  fi
}

# expect_contains <label> <needle> <haystack>
expect_contains() {
  local label="$1" needle="$2" haystack="$3"
  if echo "$haystack" | grep -q -F "$needle"; then
    echo "  ${C_GREEN}✓${C_RESET} $label"
    PASS_COUNT=$((PASS_COUNT+1))
  else
    echo "  ${C_RED}✗${C_RESET} $label (missing: $needle)"
    echo "    haystack: $(echo "$haystack" | head -c 200)..."
    FAIL_COUNT=$((FAIL_COUNT+1))
  fi
}

# tenant_to_cardholder_codes — returns "EU_CODE HK_CODE REPORTING_CODE"
tenant_to_cardholder_codes() {
  local eu hk rep
  eu=$(kubectl --context="${CLUSTER2}" -n tenant-payments exec deploy/payments-api-eu -c curl -- \
    curl -s -o /dev/null -w "%{http_code}" --max-time 10 \
    http://cardholder.tenant-payments.mesh.internal:8000/status/200 2>/dev/null)
  hk=$(kubectl --context="${CLUSTER2}" -n tenant-payments exec deploy/payments-api-hk -c curl -- \
    curl -s -o /dev/null -w "%{http_code}" --max-time 10 \
    http://cardholder.tenant-payments.mesh.internal:8000/status/200 2>/dev/null)
  rep=$(kubectl --context="${CLUSTER2}" -n tenant-analytics exec deploy/reporting -c curl -- \
    curl -s -o /dev/null -w "%{http_code}" --max-time 10 \
    http://cardholder.tenant-payments.mesh.internal:8000/status/200 2>/dev/null)
  echo "$eu $hk $rep"
}

summarize() {
  echo
  if [ "$FAIL_COUNT" -eq 0 ]; then
    echo "${C_GREEN}✓ ${PASS_COUNT}/${PASS_COUNT} checks passed${C_RESET}"
    return 0
  else
    echo "${C_RED}✗ ${FAIL_COUNT} check(s) failed (${PASS_COUNT} passed)${C_RESET}"
    return 1
  fi
}
