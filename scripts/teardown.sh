#!/usr/bin/env bash
set -euo pipefail

CLUSTER_NAME="${CLUSTER_NAME:-poc-devops}"

echo "=== Destruindo cluster Kind (${CLUSTER_NAME}) ==="
kind delete cluster --name "${CLUSTER_NAME}"
echo "Cluster '${CLUSTER_NAME}' removido com sucesso."
echo "Para recriar toda a stack do zero, execute: ./scripts/bootstrap.sh"
