#!/usr/bin/env bash
set -euo pipefail

CLUSTER_NAME="${CLUSTER_NAME:-poc-devops}"

echo "=== [1/7] Criando cluster Kind (${CLUSTER_NAME}) ==="
if kind get clusters | grep -q "^${CLUSTER_NAME}$"; then
  echo "Cluster '${CLUSTER_NAME}' já existe. Pulando criação."
else
  if [ -f infra/kind/kind-config.yaml ]; then
    kind create cluster --name "${CLUSTER_NAME}" --config infra/kind/kind-config.yaml
  else
    kind create cluster --name "${CLUSTER_NAME}"
  fi
fi

echo "=== [2/7] Instalando Ingress NGINX e expondo porta 8080 ==="
kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/main/deploy/static/provider/kind/deploy.yaml
kubectl wait --namespace ingress-nginx \
  --for=condition=ready pod \
  --selector=app.kubernetes.io/component=controller \
  --timeout=180s

kubectl patch svc ingress-nginx-controller -n ingress-nginx --type='json' \
  -p='[{"op": "add", "path": "/spec/ports/-", "value": {"name": "http-8080", "port": 8080, "protocol": "TCP", "targetPort": 80}}]' 2>/dev/null || true

echo "=== [3/7] Atualizando repositórios Helm ==="
helm repo add harbor https://helm.goharbor.io 2>/dev/null || true
helm repo add kyverno https://kyverno.github.io/kyverno/ 2>/dev/null || true
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts 2>/dev/null || true
helm repo add grafana https://grafana.github.io/helm-charts 2>/dev/null || true
helm repo add argo https://argoproj.github.io/argo-helm 2>/dev/null || true
helm repo add sonarqube https://SonarSource.github.io/helm-chart-sonarqube 2>/dev/null || true
helm repo update

echo "=== [4/7] Instalando Harbor Container Registry ==="
kubectl create namespace harbor --dry-run=client -o yaml | kubectl apply -f -
if [ -f infra/harbor/values.yaml ]; then
  helm upgrade --install harbor harbor/harbor -n harbor -f infra/harbor/values.yaml --wait --timeout=10m
else
  helm upgrade --install harbor harbor/harbor -n harbor \
    --set expose.type=ingress \
    --set expose.tls.enabled=false \
    --set expose.ingress.hosts.core=harbor.local \
    --set externalURL=http://harbor.local:8080 \
    --set harborAdminPassword=Harbor@12345 \
    --wait --timeout=10m
fi

echo "=== [5/7] Instalando Kyverno com Registry HTTP Local e Políticas ==="
kubectl create namespace kyverno --dry-run=client -o yaml | kubectl apply -f -
helm upgrade --install kyverno kyverno/kyverno -n kyverno --wait --timeout=5m

INGRESS_IP=$(kubectl get svc -n ingress-nginx ingress-nginx-controller -o jsonpath='{.spec.clusterIP}')

kubectl patch deployment kyverno-admission-controller -n kyverno --type='json' -p="[
  {\"op\": \"add\", \"path\": \"/spec/template/spec/hostAliases\", \"value\": [{\"ip\": \"${INGRESS_IP}\", \"hostnames\": [\"harbor.local\"]}]},
  {\"op\": \"add\", \"path\": \"/spec/template/spec/containers/0/args/-\", \"value\": \"--allowInsecureRegistry=true\"}
]" 2>/dev/null || true
kubectl rollout status deployment/kyverno-admission-controller -n kyverno --timeout=120s

kubectl create namespace poc-app --dry-run=client -o yaml | kubectl apply -f -
[ -d infra/kyverno ] && kubectl apply -f infra/kyverno/

echo "=== [6/7] Instalando Observabilidade (Loki + Prometheus + Grafana) ==="
kubectl create namespace monitoring --dry-run=client -o yaml | kubectl apply -f -

if [ -f infra/loki/values.yaml ]; then
  helm upgrade --install loki grafana/loki-stack -n monitoring -f infra/loki/values.yaml --wait --timeout=5m
fi

helm upgrade --install prometheus prometheus-community/kube-prometheus-stack \
  -n monitoring \
  -f infra/observability/values-prometheus.yaml

kubectl apply -f infra/observability/dashboard-poc-api.yaml
kubectl rollout status deployment/prometheus-grafana -n monitoring --timeout=180s

echo "=== [7/7] Instalando ArgoCD e SonarQube (se configurados em infra/) ==="
if [ -f infra/argocd/values.yaml ]; then
  kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -
  helm upgrade --install argocd argo/argo-cd -n argocd -f infra/argocd/values.yaml --wait --timeout=5m
  [ -f infra/argocd/application.yaml ] && kubectl apply -f infra/argocd/application.yaml
fi

if [ -f infra/sonarqube/values.yaml ]; then
  kubectl create namespace sonarqube --dry-run=client -o yaml | kubectl apply -f -
  helm upgrade --install sonarqube sonarqube/sonarqube -n sonarqube -f infra/sonarqube/values.yaml --wait --timeout=10m
fi

echo ""
echo "=== Bootstrap concluído com sucesso! ==="
echo "Harbor:     http://harbor.local:8080 (admin / Harbor@12345)"
echo "Grafana:    http://grafana.local:8080 (admin / Admin@12345)"
echo "Prometheus: http://prometheus.local:8080"
