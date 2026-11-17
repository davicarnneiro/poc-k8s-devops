# POC Kubernetes Local DevOps

Ambiente Kubernetes **100% local** (sem Cloud) que demonstra um ciclo completo de entrega de software:
CI/CD, segurança de supply chain, GitOps, deploy canary e observabilidade.

> Relatório de decisões técnicas, dificuldades e melhorias: [docs/RELATORIO.md](docs/RELATORIO.md)
> Checklist de evidências: [docs/evidencias/README.md](docs/evidencias/README.md)

## 1. Arquitetura

```
 Dev ──push──▶ GitHub ──▶ GitHub Actions (runner self-hosted, na sua máquina)
                              │
        1. pytest + SonarQube (SAST)
        2. docker build (multi-stage) + Trivy (bloqueia CRITICAL/HIGH)
        3. push no Harbor + assinatura Cosign (por digest)
        4. commit da nova tag em chart/.../values.yaml  [skip ci]
                              │
                              ▼
                    ArgoCD (GitOps) detecta o commit
                              │
                              ▼
   ┌───────────────── cluster kind (1 control-plane + 2 workers) ─────────────────┐
   │  Kyverno ──admite pod?──▶ (sem :latest, com limits, imagem assinada)         │
   │  Argo Rollouts: canary 10% → 25% → 50% → 100% via Ingress NGINX              │
   │  HPA (metrics-server)    ConfigMap + Secret → env da aplicação               │
   │  Prometheus + Alertmanager + Grafana (métricas)  Loki + Promtail (logs)      │
   └──────────────────────────────────────────────────────────────────────────────┘
```

| Requisito do desafio | Implementação |
|---|---|
| Cluster local | kind (`infra/kind-config.yaml`) |
| Registry | Harbor (com Trivy habilitado) |
| Aplicação + `/healthz` | FastAPI em `app/` |
| Dockerfile multi-stage + testes | `app/Dockerfile`, `app/tests/` (pytest) |
| Chart Helm | `chart/poc-devops-api` (Rollout, Service, Ingress, HPA, ConfigMap, Secret, ServiceMonitor) |
| CI/CD self-hosted | GitHub Actions + runner local (`.github/workflows/ci-cd.yaml`) |
| SAST / scan de imagem | SonarQube / Trivy |
| Métricas e logs | Prometheus + Grafana / Loki + Promtail |
| Políticas | Kyverno: proíbe `:latest`, exige limits e **imagem assinada** |
| Diferenciais | Cosign, ArgoCD (GitOps), Canary (Argo Rollouts), alerta Prometheus |

## 2. Pré-requisitos

| Ferramenta | Versão testada |
|---|---|
| Docker | 24+ |
| kind | 0.33 |
| kubectl | 1.31 |
| helm | 3.x |
| cosign | 2.x |
| make, git, python3 (com `venv`) | — |

Recursos: **~12 GB de RAM livres e 6 CPUs** (SonarQube e Harbor são pesados). Linux.

## 3. Preparação da máquina (uma vez)

**3.1 `/etc/hosts`** — todos os serviços usam `*.local` na porta 8080:

```
127.0.0.1 harbor.local sonar.local argocd.local grafana.local prometheus.local app.local
```

**3.2 Docker aceitar o Harbor sem TLS** — `/etc/docker/daemon.json`:

```json
{ "insecure-registries": ["harbor.local", "harbor.local:8080"] }
```

Depois: `sudo systemctl restart docker`.

**3.3 Par de chaves do Cosign** (senha **vazia**, apenas Enter):

```bash
cosign generate-key-pair      # gera cosign.key e cosign.pub
mkdir -p .cosign && mv cosign.key .cosign/   # .cosign/ está no .gitignore
cp cosign.pub infra/cosign/cosign.pub
```

Cole o conteúdo de `cosign.pub` no campo `attestors[].cosign.key.data` de
`infra/kyverno/verify-image-signature.yaml`. **Nunca versione `cosign.key`.**

## 4. Subindo e derrubando o ambiente

Existem três formas de executar. Todos os alvos são idempotentes (podem ser repetidos sem problema).

### 4.1 Tudo de uma vez

```bash
make all          # sobe TUDO, na ordem correta, e mostra as credenciais no final
```

Equivale a: `up` + `rollouts` + `platform` + `policies` + `observability` + `app` + `credentials`
(antes, verifica o `/etc/hosts` com `hosts-check`).

### 4.2 Só o cluster base

```bash
make up           # cluster kind + Ingress NGINX + Metrics Server
```

Útil para validar o cluster e o ingress antes de instalar o restante. Depois, continue com `make all`
(ele reaproveita o que já existe) ou com os passos separados abaixo.

### 4.3 Passo a passo separado (útil para explicar e depurar)

Execute **nesta ordem** (cada passo depende do anterior):

```bash
make up              # 1. Cluster kind, Ingress NGINX, Metrics Server
make rollouts        # 2. Argo Rollouts (CRD Rollout usada pelo chart)
make platform        # 3. Harbor, SonarQube, Kyverno, ArgoCD (+ configura o containerd dos nós para o Harbor)
make policies        # 4. Políticas Kyverno no namespace poc-app (precisa do Kyverno pronto)
make observability   # 5. Prometheus, Grafana, Alertmanager, Loki/Promtail e dashboard da API
make app             # 6. Registra o Application no ArgoCD (GitOps)
make credentials     # 7. Mostra URLs e senhas
```

### 4.4 Derrubando o ambiente

```bash
make down         # remove o cluster kind (apaga TODOS os dados e componentes)
```

Para recriar do zero: `make down && make all`.

### 4.5 Outros comandos úteis

```bash
make help           # lista todos os alvos
make status         # nós e pods de todos os namespaces
make rollouts-cli   # (opcional) plugin 'kubectl argo rollouts' no host, para ver o canary ao vivo
```

> Aguarde os pods ficarem `Running` (`make status`). SonarQube e Harbor levam alguns minutos.

> ⚠️ Se recriar o cluster, rode `make all` de novo: o ClusterIP do ingress muda e os nós precisam ser reconfigurados.

## 5. Configurando o CI/CD (uma vez)

**5.1 Harbor** — acesse http://harbor.local:8080 (`admin` / `Harbor@12345`) → *Projects → New Project* → nome `poc-devops`.

**5.2 SonarQube** — http://sonar.local:8080 (`admin`/`admin`, troque a senha) → *My Account → Security → Generate Token*.

**5.3 Secrets do GitHub** (*Settings → Secrets and variables → Actions*):

| Secret | Valor |
|---|---|
| `SONAR_TOKEN` | token do passo 5.2 |
| `HARBOR_USER` / `HARBOR_PASSWORD` | `admin` / `Harbor@12345` |
| `COSIGN_PRIVATE_KEY` | conteúdo de `.cosign/cosign.key` |

Em *Settings → Actions → General → Workflow permissions* escolha **Read and write** (o pipeline faz commit da tag).

**5.4 Runner self-hosted** — *Settings → Actions → Runners → New self-hosted runner* (Linux x64) e siga os comandos exibidos
(`./config.sh ...` e `./run.sh`). O runner roda na sua máquina e precisa de `docker`, `cosign`, `python3`, `git` e acesso a `harbor.local:8080`/`sonar.local:8080`.

**5.5 ArgoCD precisa ler o repositório.** `infra/argocd/application.yaml` aponta para o repositório no GitHub (público). Se for privado, cadastre a credencial em *ArgoCD → Settings → Repositories*. Ajuste `repoURL` para o seu fork, se necessário.

## 6. Executando o pipeline

Faça push na `main` (ou *Actions → CI/CD → Run workflow*). Etapas:

1. **Lint do chart + testes + SonarQube** — `helm lint`/`helm template`, pytest com cobertura e análise SAST (o pipeline **falha** se o Quality Gate reprovar)
2. **Build + Trivy** — falha se houver vulnerabilidade CRITICAL/HIGH com correção disponível
3. **Push + Cosign** — envia ao Harbor e assina o digest
4. **GitOps** — atualiza `image.tag` no `values.yaml` (tag = SHA curto do commit, **imutável**; se disparar por tag git `vX.Y.Z`, usa a semver)

O ArgoCD detecta o commit e o Argo Rollouts inicia o canary.

## 7. Validação (comandos para demonstrar)

```bash
# Aplicação (note secret_loaded=true e a mensagem vinda do ConfigMap)
curl http://app.local:8080/
curl http://app.local:8080/healthz
curl http://app.local:8080/metrics | head

# GitOps / canary
kubectl get application -n argocd
kubectl argo rollouts get rollout poc-devops-api -n poc-app --watch   # plugin opcional: make rollouts-cli
kubectl get hpa,pods,ingress -n poc-app

# Política 1: :latest é bloqueado
kubectl run teste --image=nginx:latest -n poc-app
#   → Error ... Imagens com tag ':latest' ... sao proibidas

# Política 2: imagem sem assinatura é bloqueada
docker pull nginx:1.27 && docker tag nginx:1.27 harbor.local:8080/poc-devops/nao-assinada:1.0
docker push harbor.local:8080/poc-devops/nao-assinada:1.0
kubectl run teste --image=harbor.local:8080/poc-devops/nao-assinada:1.0 -n poc-app
#   → Error ... A imagem deve estar assinada com a chave oficial do Cosign.

# Verificar a assinatura manualmente
cosign verify --key infra/cosign/cosign.pub --allow-insecure-registry \
  harbor.local:8080/poc-devops/poc-devops-api:<TAG>

# HPA (gerar carga)
kubectl run load --rm -it --image=busybox:1.36 -n poc-app -- \
  sh -c 'while true; do wget -q -O- http://poc-devops-api/ >/dev/null; done'
```

**Observabilidade:** Grafana http://grafana.local:8080 (dashboard *POC DevOps API*; *Explore → Loki* para logs) e Prometheus http://prometheus.local:8080 (*Alerts* → `PocAppPodDown`).

## 8. Rollback

**Durante um canary (antes de 100%)**
```bash
kubectl argo rollouts abort poc-devops-api -n poc-app    # volta 100% do tráfego à versão estável
```

**Depois de promovido — via GitOps (recomendado, deixa histórico)**
```bash
git revert <commit "chore(cd): update image tag ...">
git push origin main        # ArgoCD aplica a tag anterior (já assinada e no Harbor)
```

**Emergência**
```bash
kubectl argo rollouts undo poc-devops-api -n poc-app
# O ArgoCD (selfHeal) reverte mudanças manuais; para segurar, pause o sync do Application.
```

## 9. Troubleshooting

| Sintoma | Causa provável | Solução |
|---|---|---|
| `ImagePullBackOff` do Harbor | containerd dos nós sem config do registry (ClusterIP mudou) | `make configure-kind-registry` |
| `docker push` → "http: server gave HTTP response" | falta `insecure-registries` | seção 3.2 e reiniciar Docker |
| Pod negado: "imagem deve estar assinada" | imagem não assinada, ou `cosign.pub` da política difere da chave usada | rode o pipeline completo; confira a chave em `verify-image-signature.yaml` |
| Kyverno não consegue verificar (erro de rede/HTTP) | admission controller sem `hostAliases`/`--allowInsecureRegistry` | `make kyverno-registry` |
| ArgoCD `Unknown`/`ComparisonError` | repositório privado ou sem internet | seção 5.5 |
| ArgoCD: `no matches for kind "Rollout"` | CRD do Rollouts ausente | `make rollouts` |
| App `Degraded` logo após instalar | a tag do `values.yaml` ainda não existe no Harbor | rode o pipeline uma vez (seção 6) |
| HPA `<unknown>` | metrics-server sem `--kubelet-insecure-tls` | `make metrics-server` |
| Sonar: "Not authorized" | `SONAR_TOKEN` ausente/errado | seção 5.2/5.3 |
| Pipeline falha no `git push` (403) | permissão de escrita do workflow | seção 5.3 |
| `make all` para em `hosts-check` | faltam entradas no `/etc/hosts` | seção 3.1 |
| Pods `Pending` | falta de memória | feche apps; reduza `jvmOpts` do SonarQube |

## 10. Estrutura do repositório

```
app/                 API FastAPI, Dockerfile multi-stage, testes, config do Sonar
chart/poc-devops-api Chart Helm (Rollout canary, HPA, Ingress, ConfigMap, Secret, ServiceMonitor)
infra/
  kind-config.yaml   cluster (3 nós, portas 8080/8443)
  values/            values Helm de cada componente (versões fixas no Makefile)
  kyverno/           políticas (sem :latest + limits; assinatura Cosign)
  argocd/            Application (GitOps)
  dashboards/        dashboard Grafana
  cosign/cosign.pub  chave pública
.github/workflows/   pipeline CI/CD
docs/                relatório e evidências
Makefile             ponto único de entrada
```

## 11. Limpeza

```bash
make down      # remove o cluster
```

## 12. Limitações conhecidas (POC)

Credenciais em texto nos values e `Secret` em `values.yaml` (em produção: Sealed Secrets/SOPS/Vault); Harbor sem TLS; um único cluster; sem NetworkPolicy. Detalhes e roadmap em [docs/RELATORIO.md](docs/RELATORIO.md).
