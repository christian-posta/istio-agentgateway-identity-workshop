#!/usr/bin/env bash
# teardown.sh — Delete the workshop kind clusters and clean up kubeconfig contexts.
#
# Usage: ./teardown.sh

set -uo pipefail

# Clear any stale lock from a prior failed kind run.
rm -f "$HOME/.kube/config.lock"

# Delete sequentially — running `kind delete cluster` in parallel races on
# ~/.kube/config.lock and leaves stale context entries when one loses the race.
for name in cluster1 cluster2; do
  if kind get clusters 2>/dev/null | grep -qx "${name}"; then
    echo "Deleting kind cluster: ${name}"
    kind delete cluster --name "${name}" || true
  else
    echo "kind cluster '${name}' not present — skipping"
  fi

  # Belt-and-suspenders: scrub any stale kubeconfig entries even if kind succeeded,
  # or if a prior parallel `kind delete` lost the lock and left them behind.
  ctx="kind-${name}"
  kubectl config delete-context "${ctx}" >/dev/null 2>&1 || true
  kubectl config delete-cluster "${ctx}" >/dev/null 2>&1 || true
  kubectl config delete-user    "${ctx}" >/dev/null 2>&1 || true
done

echo "Done."
