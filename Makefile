CLUSTER_NAME := poc-devops
KIND_CONFIG  := infra/kind-config.yaml

.PHONY: up down cluster-create ingress metrics-server status

up: cluster-create ingress metrics-server
	@echo "✅ Cluster $(CLUSTER_NAME), Ingress NGINX e Metrics Server prontos!"

cluster-create:
	@if ! kind get clusters | grep -q "^$(CLUSTER_NAME)$$"; then \
		kind create cluster --config $(KIND_CONFIG); \
	else \
		echo "⚠️  Cluster $(CLUSTER_NAME) já existe."; \
	fi

ingress:
	@echo "📦 Instalando Ingress NGINX para kind..."
	kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/main/deploy/static/provider/kind/deploy.yaml
	@echo "⏳ Aguardando Ingress NGINX ficar pronto..."
	kubectl wait --namespace ingress-nginx \
		--for=condition=ready pod \
		--selector=app.kubernetes.io/component=controller \
		--timeout=180s

metrics-server:
	@echo "📊 Instalando Metrics Server (necessário para HPA)..."
	kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml
	kubectl patch -n kube-system deployment metrics-server --type='json' \
		-p='[{"op": "add", "path": "/spec/template/spec/containers/0/args/-", "value": "--kubelet-insecure-tls"}]'

status:
	kubectl get nodes -o wide
	kubectl get pods -A

down:
	kind delete cluster --name $(CLUSTER_NAME)



.PHONY: helm-repos platform harbor sonarqube kyverno argocd configure-kind-registry credentials

helm-repos:
	helm repo add harbor https://helm.goharbor.io
	helm repo add sonarqube https://SonarSource.github.io/helm-chart-sonarqube
	helm repo add kyverno https://kyverno.github.io/kyverno/
	helm repo add argo https://argoproj.github.io/argo-helm
	helm repo update

platform: helm-repos configure-kind-registry harbor sonarqube kyverno argocd
	@echo "🚀 Plataforma (Harbor, SonarQube, Kyverno, ArgoCD) instalada!"

configure-kind-registry:
	@echo "🔧 Configurando containerd nos nós kind para harbor.local..."
	@INGRESS_IP=$$(kubectl get svc -n ingress-nginx ingress-nginx-controller -o jsonpath='{.spec.clusterIP}'); \
	for node in $$(kind get nodes --name $(CLUSTER_NAME)); do \
		docker exec $$node mkdir -p /etc/containerd/certs.d/harbor.local; \
		docker exec $$node sh -c "printf 'server = \"http://%s\"\n[host.\"http://%s\"]\n  capabilities = [\"pull\", \"resolve\", \"push\"]\n  override_path = true\n' '$$INGRESS_IP' '$$INGRESS_IP' > /etc/containerd/certs.d/harbor.local/hosts.toml"; \
	done

harbor:
	helm upgrade --install harbor harbor/harbor \
		--namespace harbor --create-namespace \
		-f infra/values/harbor-values.yaml

sonarqube:
	helm upgrade --install sonarqube sonarqube/sonarqube \
		--namespace sonarqube --create-namespace \
		-f infra/values/sonarqube-values.yaml

kyverno:
	helm upgrade --install kyverno kyverno/kyverno \
		--namespace kyverno --create-namespace \
		--set admissionController.replicas=1 \
		--set backgroundController.replicas=1 \
		--set cleanupController.replicas=1 \
		--set reportsController.replicas=1

argocd:
	helm upgrade --install argocd argo/argo-cd \
		--namespace argocd --create-namespace \
		-f infra/values/argocd-values.yaml

credentials:
	@echo "🔑 Harbor:    http://harbor.local   (admin / Harbor@12345)"
	@echo "🔑 SonarQube: http://sonar.local    (admin / admin)"
	@echo -n "🔑 ArgoCD:    http://argocd.local   (admin / "
	@kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d; echo ")"


.PHONY: observability

observability:
	helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
	helm repo add grafana https://grafana.github.io/helm-charts
	helm repo update
	helm upgrade --install kube-prometheus-stack prometheus-community/kube-prometheus-stack \
		--namespace monitoring --create-namespace \
		-f infra/values/prometheus-values.yaml
	helm upgrade --install loki grafana/loki-stack \
		--namespace monitoring \
		--set promtail.enabled=true \
		--set loki.persistence.enabled=false \
		--set loki.resources.requests.cpu=100m \
		--set loki.resources.requests.memory=256Mi
	@echo "📊 Grafana disponivel em: http://grafana.local (admin / admin)"