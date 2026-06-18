#!/usr/bin/env bash
# runall.sh — Run all 5 part scripts in sequence. Each part builds on previous state,
# so the order matters. Exits non-zero on the first failure.
#
# Prerequisites: setup.sh has been run; CLUSTER1 / CLUSTER2 exported.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"

start=$(date +%s)
failures=0

for script in 01-multicluster.sh 02-identity-authz.sh 03-workload-claims.sh 04-egress-wit.sh 05-obo-token-exchange.sh; do
  if "${HERE}/${script}"; then
    echo
  else
    rc=$?
    echo
    echo "=== ${script} FAILED (exit ${rc}). Stopping. ==="
    failures=$((failures+1))
    break
  fi
done

elapsed=$(( $(date +%s) - start ))
echo "════════════════════════════════════════════════════════════"
if [ "$failures" -eq 0 ]; then
  echo "  ✓ ALL 5 PARTS PASSED  (${elapsed}s)"
  exit 0
else
  echo "  ✗ ${failures} part(s) FAILED  (${elapsed}s)"
  exit 1
fi
