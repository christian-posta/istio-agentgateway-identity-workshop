#!/usr/bin/env bash
# reset-workshop.sh — Wipe workshop content (apps, policies, agents) but keep the
# infrastructure (kind clusters, Istio, EAG, multicluster peering) intact.
#
# Use this when you want to re-run ./parts/runall.sh from scratch without paying
# the ~5-7 min cost of ./setup.sh.

set -uo pipefail

: "${CLUSTER1:?CLUSTER1 must be set, e.g. export CLUSTER1=kind-cluster1}"
: "${CLUSTER2:?CLUSTER2 must be set, e.g. export CLUSTER2=kind-cluster2}"

# Namespaces created by the part scripts:
#   tenant-payments      — Parts 1-3 (cluster1 + cluster2)
#   tenant-analytics     — Parts 1-3 (cluster2)
#   common-infrastructure — Part 4 (cluster1)
#   egress-client        — Part 4 (cluster1)
#   tokenexchange-test   — Part 5 (cluster1)
#   agents               — Part 5 (cluster1)
WORKSHOP_NS=(tenant-payments tenant-analytics common-infrastructure egress-client tokenexchange-test agents)

echo "Deleting workshop namespaces on both clusters..."
for ctx in "${CLUSTER1}" "${CLUSTER2}"; do
  for ns in "${WORKSHOP_NS[@]}"; do
    kubectl --context="${ctx}" delete ns "${ns}" --ignore-not-found --wait=false 2>&1 | head -1 &
  done
done
wait

echo "Waiting for namespaces to finalize..."
for ctx in "${CLUSTER1}" "${CLUSTER2}"; do
  for ns in "${WORKSHOP_NS[@]}"; do
    while kubectl --context="${ctx}" get ns "${ns}" >/dev/null 2>&1; do sleep 2; done
  done
done

echo "Done. Infra (Istio, EAG, peering) is intact."
echo "Re-run ./parts/runall.sh to validate from clean state."
