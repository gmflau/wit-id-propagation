#!/bin/bash
set -e

# Mirrors the resource names created by setup-3-kind-clusters.sh

CLUSTER1_NAME="cluster-1"
CLUSTER2_NAME="cluster-2"
CLUSTER3_NAME="cluster-3"

echo "Deleting the three Kind clusters..."
kind delete cluster --name "$CLUSTER1_NAME"
kind delete cluster --name "$CLUSTER2_NAME"
kind delete cluster --name "$CLUSTER3_NAME"

echo ""
echo "Cleanup complete. If you started 'sudo cloud-provider-kind' in a dedicated"
echo "terminal, Ctrl-C it there too."
