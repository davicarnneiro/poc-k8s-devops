#!/usr/bin/env bash
set -euo pipefail

NAMESPACE="argo-rollouts"
CLI_BIN="/usr/local/bin/kubectl-argo-rollouts"

echo "1. Criando namespace '${NAMESPACE}' (se não existir)..."
kubectl create namespace "${NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -

echo "2. Instalando manifestos oficiais do Argo Rollouts Controller..."
kubectl apply --server-side -n "${NAMESPACE}" -f https://github.com/argoproj/argo-rollouts/releases/latest/download/install.yaml

echo "3. Aguardando deployment do Argo Rollouts ficar disponível..."
kubectl rollout status deployment/argo-rollouts -n "${NAMESPACE}" --timeout=180s

echo "4. Instalando plugin CLI kubectl-argo-rollouts no host..."
TMP_BIN=$(mktemp)
curl -fsSL -o "${TMP_BIN}" https://github.com/argoproj/argo-rollouts/releases/latest/download/kubectl-argo-rollouts-linux-amd64
chmod +x "${TMP_BIN}"
sudo mv "${TMP_BIN}" "${CLI_BIN}"

echo "5. Validando instalação..."
kubectl get pods -n "${NAMESPACE}"
kubectl argo rollouts version --short

echo "Argo Rollouts instalado com sucesso!"
