#!/usr/bin/env bash
# teardown.sh — Delete the workshop kind clusters and clean up kubeconfig contexts.
#
# Usage: ./teardown.sh

set -euo pipefail

echo "Deleting kind clusters: cluster1  cluster2"
kind delete cluster --name cluster1 &
kind delete cluster --name cluster2 &
wait
echo "Done. kind clusters deleted."
