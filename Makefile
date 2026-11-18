##############################################################################
# POC Kubernetes Local DevOps - ponto unico de entrada
#   make all      -> sobe TUDO na ordem correta
#   make help     -> lista os alvos
#   make down     -> destroi o cluster
##############################################################################

CLUSTER_NAME := poc-devops
KIND_CONFIG  := infra/kind-config.yaml

# Versoes fixas (reprodutibilidade)
INGRESS_NGINX_VERSION  := controller-v1.12.1
METRICS_SERVER_VERSION := v0.7.2
ARGO_ROLLOUTS_VERSION  := v1.8.3
HARBOR_CHART_VERSION     := 1.19.4
SONARQUBE_CHART_VERSION  := 2026.5.1005
KYVERNO_CHART_VERSION    := 3.10.0
ARGOCD_CHART_VERSION     := 10.18.0
PROMETHEUS_CHART_VERSION := 93.3.1
LOKI_CHART_VERSION       := 2.10.3

.DEFAULT_GOAL := help
.PHONY: help all up cluster-create ingress metrics-server rollouts \
        helm-repos platform configure-kind-registry harbor sonarqube \
        kyverno kyverno-registry policies argocd app observability rollouts-cli \
        credentials status hosts-check harbor-project smoke-test unsigned-image down

help: ## Lista os alvos
	@grep -E '^[a-zA-Z_-]+:.*## ' $(MAKEFILE_LIST) | awk -F':.*## ' '{printf "  \033[36m%-24s\033[0m %s\n", $$1, $$2}'

# Ordem: cluster -> base -> plataforma -> politicas -> observabilidade -> app
all: hosts-check up rollouts platform policies observability app credentials ## Sobe todo o ambiente
	@echo "✅ Ambiente completo! Proximo passo: configurar o CI/CD: README, Fase 3 (projeto no Harbor, Sonar, secrets e runner)."

## ---------------------------------------------------------------- Cluster
up: cluster-create ingress metrics-server ## Cluster kind + Ingress + Metrics Server
	@echo "✅ Cluster $(CLUSTER_NAME) pronto"

cluster-create:
	@if ! kind get clusters | grep -q "^$(CLUSTER_NAME)$$"; then \
		kind create cluster --config $(KIND_CONFIG); \
	else \
		echo "⚠️  Cluster $(CLUSTER_NAME) ja existe."; \
	fi

ingress:
	@echo "📦 Instalando Ingress NGINX ($(INGRESS_NGINX_VERSION))..."
	kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/$(INGRESS_NGINX_VERSION)/deploy/static/provider/kind/deploy.yaml
	kubectl wait --namespace ingress-nginx --for=condition=ready pod \
		--selector=app.kubernetes.io/component=controller --timeout=300s
	@# Expoe tambem a porta 8080 no Service: nos e pods acessam harbor.local:8080 pelo ClusterIP (igual ao host)
	@kubectl get svc -n ingress-nginx ingress-nginx-controller -o jsonpath='{.spec.ports[*].port}' | grep -qw 8080 || \
		kubectl patch svc ingress-nginx-controller -n ingress-nginx --type=json \
		-p='[{"op":"add","path":"/spec/ports/-","value":{"name":"http-8080","port":8080,"protocol":"TCP","targetPort":80}}]'

metrics-server:
	@echo "📊 Instalando Metrics Server $(METRICS_SERVER_VERSION) (necessario para HPA)..."
	kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/download/$(METRICS_SERVER_VERSION)/components.yaml
	@kubectl get deploy -n kube-system metrics-server -o jsonpath='{.spec.template.spec.containers[0].args}' | grep -q kubelet-insecure-tls || \
		kubectl patch -n kube-system deployment metrics-server --type='json' \
		-p='[{"op": "add", "path": "/spec/template/spec/containers/0/args/-", "value": "--kubelet-insecure-tls"}]'

# O chart usa a CRD Rollout: precisa existir ANTES do ArgoCD sincronizar o app
rollouts: ## Argo Rollouts (canary)
	@echo "🐤 Instalando Argo Rollouts $(ARGO_ROLLOUTS_VERSION)..."
	kubectl create namespace argo-rollouts --dry-run=client -o yaml | kubectl apply -f -
	kubectl apply --server-side -n argo-rollouts -f https://github.com/argoproj/argo-rollouts/releases/download/$(ARGO_ROLLOUTS_VERSION)/install.yaml
	kubectl rollout status deployment/argo-rollouts -n argo-rollouts --timeout=300s

# Opcional: plugin 'kubectl argo rollouts' no host (acompanhar o canary em tempo real)
rollouts-cli: ## Instala o plugin kubectl-argo-rollouts no host (usa sudo)
	curl -fsSL -o /tmp/kubectl-argo-rollouts https://github.com/argoproj/argo-rollouts/releases/download/$(ARGO_ROLLOUTS_VERSION)/kubectl-argo-rollouts-linux-amd64
	chmod +x /tmp/kubectl-argo-rollouts
	sudo mv /tmp/kubectl-argo-rollouts /usr/local/bin/kubectl-argo-rollouts
	kubectl argo rollouts version

## ------------------------------------------------------------ Plataforma
helm-repos:
	helm repo add harbor https://helm.goharbor.io --force-update
	helm repo add sonarqube https://SonarSource.github.io/helm-chart-sonarqube --force-update
	helm repo add kyverno https://kyverno.github.io/kyverno/ --force-update
	helm repo add argo https://argoproj.github.io/argo-helm --force-update
	helm repo add prometheus-community https://prometheus-community.github.io/helm-charts --force-update
	helm repo add grafana https://grafana.github.io/helm-charts --force-update
	helm repo update

platform: helm-repos configure-kind-registry harbor sonarqube kyverno argocd ## Harbor, SonarQube, Kyverno, ArgoCD
	@echo "🚀 Plataforma instalada!"

# Nos do kind precisam resolver harbor.local -> ClusterIP do ingress (via /etc/hosts do no) e falar HTTP em :8080.
# Importante: o nome harbor.local deve ser mantido (cabecalho Host), senao o Ingress responde 404.
configure-kind-registry:
	@echo "🔧 Configurando nos do kind para harbor.local:8080..."
	@INGRESS_IP=$$(kubectl get svc -n ingress-nginx ingress-nginx-controller -o jsonpath='{.spec.clusterIP}'); \
	for node in $$(kind get nodes --name $(CLUSTER_NAME)); do \
		docker exec $$node mkdir -p /etc/containerd/certs.d/harbor.local:8080; \
		docker exec $$node sh -c "grep -v ' harbor.local\$$' /etc/hosts > /tmp/h && cat /tmp/h > /etc/hosts && echo '$$INGRESS_IP harbor.local' >> /etc/hosts"; \
		docker exec $$node sh -c "printf 'server = \"http://harbor.local:8080\"\n[host.\"http://harbor.local:8080\"]\n  capabilities = [\"pull\", \"resolve\", \"push\"]\n' > /etc/containerd/certs.d/harbor.local:8080/hosts.toml"; \
	done

harbor:
	helm upgrade --install harbor harbor/harbor --version $(HARBOR_CHART_VERSION) \
		--namespace harbor --create-namespace -f infra/values/harbor-values.yaml

sonarqube:
	helm upgrade --install sonarqube sonarqube/sonarqube --version $(SONARQUBE_CHART_VERSION) \
		--namespace sonarqube --create-namespace -f infra/values/sonarqube-values.yaml

kyverno: ## Kyverno (+ acesso ao registry HTTP local)
	helm upgrade --install kyverno kyverno/kyverno --version $(KYVERNO_CHART_VERSION) \
		--namespace kyverno --create-namespace -f infra/values/kyverno-values.yaml --wait --timeout 5m
	$(MAKE) kyverno-registry

# Kyverno verifica a assinatura direto no Harbor (harbor.local:8080, HTTP).
# O pod precisa resolver harbor.local para o ClusterIP do ingress (porta 8080 exposta no alvo 'ingress').
# (--allowInsecureRegistry ja vem de infra/values/kyverno-values.yaml)
kyverno-registry:
	@INGRESS_IP=$$(kubectl get svc -n ingress-nginx ingress-nginx-controller -o jsonpath='{.spec.clusterIP}'); \
	kubectl patch deployment kyverno-admission-controller -n kyverno --type=merge \
		-p "{\"spec\":{\"template\":{\"spec\":{\"hostAliases\":[{\"ip\":\"$$INGRESS_IP\",\"hostnames\":[\"harbor.local\"]}]}}}}"
	kubectl rollout status deployment/kyverno-admission-controller -n kyverno --timeout=120s

policies: ## Politicas Kyverno (proibir :latest + verificar cosign)
	kubectl create namespace poc-app --dry-run=client -o yaml | kubectl apply -f -
	kubectl apply -f infra/kyverno/

argocd:
	helm upgrade --install argocd argo/argo-cd --version $(ARGOCD_CHART_VERSION) \
		--namespace argocd --create-namespace -f infra/values/argocd-values.yaml

app: ## Registra a aplicacao no ArgoCD (GitOps)
	kubectl apply -f infra/argocd/application.yaml

## ---------------------------------------------------------- Observabilidade
observability: helm-repos ## Prometheus + Grafana + Alertmanager + Loki/Promtail + dashboard
	helm upgrade --install kube-prometheus-stack prometheus-community/kube-prometheus-stack \
		--version $(PROMETHEUS_CHART_VERSION) --namespace monitoring --create-namespace \
		-f infra/values/prometheus-values.yaml
	helm upgrade --install loki grafana/loki-stack --version $(LOKI_CHART_VERSION) \
		--namespace monitoring -f infra/values/loki-values.yaml
	kubectl apply -f infra/dashboards/dashboard-poc-api.yaml
	@echo "📊 Grafana: http://grafana.local:8080 (admin / admin)"

## --------------------------------------------------------------- Utilitarios
hosts-check: ## Verifica /etc/hosts e insecure-registries
	@for h in harbor sonar argocd grafana prometheus app; do \
		grep -qE "[[:space:]]$$h\.local([[:space:]]|$$)" /etc/hosts || { echo "❌ Falta '$$h.local' no /etc/hosts (veja README)"; exit 1; }; \
	done
	@echo "✅ /etc/hosts ok"

# Credenciais padrao da POC (README); sobrescreva com HARBOR_USER / HARBOR_PASSWORD.
HARBOR_USER     ?= admin
HARBOR_PASSWORD ?= Harbor@12345
HARBOR_URL      ?= http://harbor.local:8080
UNSIGNED_IMAGE  := harbor.local:8080/poc-devops/nao-assinada:1.0

# Cria o projeto 'poc-devops' (PUBLICO) no Harbor. Idempotente: se ja existe, apenas garante que esta publico.
# Projeto publico evita credenciais de pull no Kyverno e nos nos (README, Fase 3.1).
harbor-project: ## Cria o projeto poc-devops (publico) no Harbor
	@code=$$(curl -s -o /dev/null -w '%{http_code}' -u "$(HARBOR_USER):$(HARBOR_PASSWORD)" -X POST $(HARBOR_URL)/api/v2.0/projects \
		-H 'Content-Type: application/json' -d '{"project_name":"poc-devops","metadata":{"public":"true"}}'); \
	case "$$code" in \
		201) echo "✅ Projeto poc-devops criado (publico)";; \
		409) curl -sf -o /dev/null -u "$(HARBOR_USER):$(HARBOR_PASSWORD)" -X PUT $(HARBOR_URL)/api/v2.0/projects/poc-devops \
			-H 'Content-Type: application/json' -d '{"metadata":{"public":"true"}}' \
			&& echo "✅ Projeto poc-devops ja existe (garantido como publico)";; \
		401) echo "❌ Harbor recusou as credenciais (HARBOR_USER/HARBOR_PASSWORD)"; exit 1;; \
		*)   echo "❌ Falha ao criar o projeto (HTTP $$code). O Harbor ja esta pronto? Veja: kubectl get pods -n harbor"; exit 1;; \
	esac

# Publica no Harbor uma imagem REAL e SEM assinatura, usada para provar a politica do Cosign.
unsigned-image: harbor-project ## Publica imagem de teste SEM assinatura no Harbor (usada pelo smoke-test)
	docker pull -q nginx:1.27-alpine
	docker tag nginx:1.27-alpine $(UNSIGNED_IMAGE)
	echo "$(HARBOR_PASSWORD)" | docker login harbor.local:8080 -u "$(HARBOR_USER)" --password-stdin
	docker push -q $(UNSIGNED_IMAGE)

smoke-test: ## Valida o ambiente de ponta a ponta (app, GitOps, politicas, observabilidade)
	@pass=0; fail=0; \
	ovr() { printf '{"spec":{"containers":[{"name":"smoke","image":"%s","resources":{"limits":{"cpu":"100m","memory":"64Mi"}}}]}}' "$$1"; }; \
	chk() { if eval "$$2" >/dev/null 2>&1; then echo "  ✅ $$1"; pass=$$((pass+1)); else echo "  ❌ $$1"; fail=$$((fail+1)); fi; }; \
	echo "🔎 Smoke test"; \
	chk "Nos do cluster Ready (3)"            '[ "$$(kubectl get nodes --no-headers | grep -c " Ready")" = 3 ]'; \
	chk "App /healthz responde 200"           'curl -sf http://app.local:8080/healthz'; \
	chk "App carregou Secret (secret_loaded)" 'curl -sf http://app.local:8080/ | grep -q "\"secret_loaded\":true"'; \
	chk "App expoe metricas HTTP"             'curl -sf http://app.local:8080/metrics | grep -q "^http_requests_total"'; \
	chk "ArgoCD Application Synced/Healthy"   'kubectl get application poc-devops-api -n argocd -o jsonpath="{.status.sync.status}/{.status.health.status}" | grep -q "^Synced/Healthy$$"'; \
	chk "Rollout Healthy"                     'kubectl get rollout poc-devops-api -n poc-app -o jsonpath="{.status.phase}" | grep -q "^Healthy$$"'; \
	chk "HPA le a CPU (metrics-server)"       'kubectl get hpa poc-devops-api -n poc-app -o jsonpath="{.status.currentMetrics[0].resource.current.averageUtilization}" | grep -qE "^[0-9]+$$"'; \
	chk "Kyverno bloqueia :latest (motivo: tag)" 'kubectl run smoke -n poc-app --dry-run=server --image=nginx:latest --overrides="$$(ovr nginx:latest)" 2>&1 | grep -q "latest"'; \
	chk "Kyverno bloqueia sem assinatura (motivo: no signatures found; precisa de make unsigned-image)" 'kubectl run smoke -n poc-app --dry-run=server --image=$(UNSIGNED_IMAGE) --overrides="$$(ovr $(UNSIGNED_IMAGE))" 2>&1 | grep -q "no signatures found"'; \
	chk "Prometheus: target da app UP"        'curl -sf "http://prometheus.local:8080/api/v1/query?query=up%7Bnamespace%3D%22poc-app%22%7D" | grep -q "\"1\"\]"'; \
	chk "Prometheus: regras PocApp carregadas" 'curl -sf http://prometheus.local:8080/api/v1/rules | grep -q PocAppHighErrorRate'; \
	chk "Grafana saudavel"                    'curl -sf http://grafana.local:8080/api/health | grep -q "\"database\": \"ok\""'; \
	chk "Loki recebe logs da app"             'kubectl get --raw "/api/v1/namespaces/monitoring/services/loki:3100/proxy/loki/api/v1/query?query=%7Bnamespace%3D%22poc-app%22%7D&limit=1" | grep -q streams'; \
	echo "Resultado: $$pass ok, $$fail falha(s)"; [ $$fail -eq 0 ]

credentials: ## Mostra URLs e credenciais
	@echo "🔑 Harbor:     http://harbor.local:8080   (admin / Harbor@12345)"
	@echo "🔑 SonarQube:  http://sonar.local:8080    (admin / admin - troca no 1o login)"
	@echo "🔑 Grafana:    http://grafana.local:8080  (admin / admin)"
	@echo "🔑 Prometheus: http://prometheus.local:8080"
	@echo "🔑 App:        http://app.local:8080"
	@echo -n "🔑 ArgoCD:     http://argocd.local:8080   (admin / "
	@kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" 2>/dev/null | base64 -d; echo ")"

status: ## Visao geral do cluster
	kubectl get nodes -o wide
	kubectl get pods -A

down: ## Destroi o cluster
	kind delete cluster --name $(CLUSTER_NAME)
