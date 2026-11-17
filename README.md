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
| Chart Helm | `chart/poc-devops-api` (**Rollout** no lugar do Deployment, pois é ele que permite o canary; Service, Ingress, HPA, ConfigMap, Secret, ServiceMonitor) |
| CI/CD self-hosted | GitHub Actions + runner local (`.github/workflows/ci-cd.yaml`) |
| SAST / scan de imagem | SonarQube / Trivy |
| Métricas e logs | Prometheus + Grafana / Loki + Promtail |
| Políticas | Kyverno: proíbe `:latest`, exige limits e **imagem assinada** |
| Diferenciais | Cosign, ArgoCD (GitOps), Canary (Argo Rollouts), alerta Prometheus |

## 2. Pré-requisitos

| Ferramenta | Versão testada |
|---|---|
| Docker | 29 (24+ deve servir) |
| kind | 0.33 |
| kubectl | 1.31 |
| helm | 4.3 |
| cosign | **3.x** (testado com 3.1; o pipeline usa flags do cosign 3, como `--new-bundle-format=false`) |
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
make smoke-test     # valida o ambiente de ponta a ponta (13 verificações)
make unsigned-image # publica no Harbor a imagem de teste SEM assinatura (usada pelo smoke-test e pela evidência do Cosign)
make rollouts-cli   # (opcional) plugin 'kubectl argo rollouts' no host, para ver o canary ao vivo
```

> Aguarde os pods ficarem `Running` (`make status`). SonarQube e Harbor levam alguns minutos.

> ⚠️ Se recriar o cluster, rode `make all` de novo: o ClusterIP do ingress muda e os nós precisam ser reconfigurados.

## 5. Configurando o CI/CD (uma vez)

**5.1 Harbor** — acesse http://harbor.local:8080 (`admin` / `Harbor@12345`) → *Projects → New Project* → nome `poc-devops`, marcando **Access Level: Public**. (Projeto privado exigiria `imagePullSecret` e credenciais no Kyverno; para a POC usamos público, e a segurança fica por conta da assinatura Cosign exigida pelo Kyverno.)

**5.2 SonarQube** — http://sonar.local:8080 (`admin`/`admin`, troque a senha) → *My Account → Security → Generate Token*.

**5.3 Secrets do GitHub** (*Settings → Secrets and variables → Actions*):

| Secret | Valor |
|---|---|
| `SONAR_TOKEN` | token do passo 5.2 |
| `HARBOR_USER` / `HARBOR_PASSWORD` | `admin` / `Harbor@12345` |
| `COSIGN_PRIVATE_KEY` | conteúdo de `.cosign/cosign.key` |

Em *Settings → Actions → General → Workflow permissions* escolha **Read and write** (o pipeline faz commit da tag).

**5.4 Runner self-hosted** — *Settings → Actions → Runners → New self-hosted runner* (Linux x64) e siga os comandos exibidos
(`./config.sh ...` e `./run.sh`). O runner roda na sua máquina e precisa de `docker`, `helm`, `cosign` 3.x, `python3` (com `venv`) e `git`, além
dos hosts `*.local` no `/etc/hosts` (seção 3.1) para alcançar `harbor.local:8080` e `sonar.local:8080`.

*Alternativa em container* (a usada nas evidências; o token vem da mesma tela *New self-hosted runner* e vale ~1 h):

```bash
docker run -d --name github-runner --restart unless-stopped --network host \
  --add-host harbor.local:127.0.0.1 --add-host sonar.local:127.0.0.1 \
  -e REPO_URL="https://github.com/SEU_USUARIO/poc-k8s-devops" \
  -e RUNNER_NAME="local-ubuntu-runner" -e RUNNER_TOKEN="<TOKEN>" -e RUNNER_WORKDIR="/tmp/runner" \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -v /usr/local/bin/cosign:/usr/local/bin/cosign:ro \
  -v /usr/local/bin/helm:/usr/local/bin/helm:ro \
  myoung34/github-runner:latest
```

O `--add-host` é necessário porque o container tem o próprio `/etc/hosts`. Confira com `docker logs github-runner` (`Listening for Jobs`).
Esse runner monta o socket do Docker do host, o que equivale a acesso root à máquina: use apenas em ambiente local de testes.

**5.5 Autorizar o ArgoCD a ler o repositório.** O `Application` (`infra/argocd/application.yaml`) aponta para o repositório no GitHub via
`repoURL`; o ArgoCD é quem faz o `git pull` dele. **Ajuste o `repoURL` para o seu repositório/fork** antes de rodar `make app`.

- **Repositório público:** nada a fazer.
- **Repositório privado:** é preciso cadastrar uma credencial. Ela vive no cluster, então **precisa ser refeita a cada `make down`**.

  1. Gere um *Personal Access Token* no GitHub (*Settings → Developer settings → Personal access tokens*), com permissão de **leitura** do
     conteúdo do repositório (fine-grained: *Contents: Read-only*).
  2. Cadastre-o no ArgoCD, por uma das duas formas:

  *Pela interface* (http://argocd.local:8080, senha em `make credentials`): *Settings → Repositories → Connect Repo* → método **HTTPS**,
  *Repository URL* igual ao `repoURL`, *Username* o seu usuário do GitHub e *Password* o token.

  *Pelo terminal* (equivalente, fácil de repetir):

  ```bash
  kubectl create secret generic repo-poc -n argocd \
    --from-literal=type=git \
    --from-literal=url=https://github.com/SEU_USUARIO/poc-k8s-devops.git \
    --from-literal=username=SEU_USUARIO \
    --from-literal=password=SEU_TOKEN
  kubectl label secret repo-poc -n argocd argocd.argoproj.io/secret-type=repository
  ```

  3. Confira: `kubectl get application -n argocd` deve mostrar `Synced`. Se aparecer `Unknown` ou `ComparisonError`
     (*repository not found / authentication required*), a credencial falta ou está errada.

> O token é um segredo: não o versione. Para quem for avaliar o projeto, o caminho mais simples é deixar o repositório **público**.

## 6. Executando o pipeline

Faça push na `main` (ou *Actions → CI/CD → Run workflow*). Etapas:

1. **Lint do chart + testes + SonarQube** — `helm lint`/`helm template`, pytest com cobertura e análise SAST (o pipeline **falha** se o Quality Gate reprovar)
2. **Build + Trivy** — falha se houver vulnerabilidade CRITICAL/HIGH com correção disponível
3. **Push + Cosign** — envia ao Harbor e assina o digest
4. **GitOps** — atualiza `image.tag` no `values.yaml` (tag = SHA curto do commit, **imutável** e rastreável até o commit)

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

**Smoke test:** rode antes `make unsigned-image` (uma vez) e depois `make smoke-test`. Ele verifica nós, app, métricas, ArgoCD, Rollout, HPA, as duas políticas do Kyverno (validando a **causa** da negação: `:latest` e `no signatures found`), Prometheus (target e regras), Grafana e Loki, e retorna erro se algo falhar.

## 8. Rollback

**Rollback automático (canary com análise)** — o Argo Rollouts consulta o Prometheus durante o canary
(`chart/.../analysistemplate.yaml`). Se a taxa de sucesso do canary ficar **< 95%** ou a latência P95 **> 500 ms**, o deploy é
**abortado sozinho** e 100% do tráfego volta para a versão estável. Sem tráfego, a análise passa (não trava deploys sem carga).

Demonstração (a app tem uma taxa de erro simulada, `APP_ERROR_RATE`, controlada por `config.errorRate` no values):

```bash
# 1. Terminal A: gerar tráfego contínuo
while true; do curl -s -o /dev/null http://app.local:8080/; sleep 0.2; done

# 2. Terminal B: acompanhar o canary
kubectl argo rollouts get rollout poc-devops-api -n poc-app --watch

# 3. Provocar a falha: em chart/poc-devops-api/values.yaml troque  errorRate: "0"  por  "1"
git commit -am "test: simula erros para demo de rollback automatico [skip ci]" && git push
#    O ConfigMap muda -> novo ReplicaSet -> canary 10% -> AnalysisRun falha -> Rollout abortado (Degraded),
#    tráfego volta 100% à versão estável.

# 4. Voltar ao normal: errorRate: "0" de novo
git commit -am "revert: remove erros simulados [skip ci]" && git push
```

`[skip ci]` evita rodar o pipeline completo, pois só o values mudou. Evidências: tela do `--watch` mostrando o `AnalysisRun` com
`Failed` e o Rollout `Degraded`, e o alerta `PocAppHighErrorRate` no Prometheus.

**Alertas configurados** (`infra/values/prometheus-values.yaml`): `PocAppPodDown`, `PocAppHighErrorRate` (5xx > 5%),
`PocAppHighLatencyP95` (> 500 ms) e `PocAppHpaMaxedOut`.

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
| `ImagePullBackOff` do Harbor (`not found`/`404`) | nós do kind sem a resolução de `harbor.local` (a entrada no `/etc/hosts` do nó se perde ao reiniciar o PC/containers, ou o ClusterIP do ingress mudou) | `make configure-kind-registry` e depois `kubectl delete pod -n poc-app -l app.kubernetes.io/name=poc-devops-api` |
| `docker push` → "http: server gave HTTP response" | falta `insecure-registries` | seção 3.2 e reiniciar Docker |
| Pod negado: "imagem deve estar assinada" | imagem não assinada, ou `cosign.pub` da política difere da chave usada | rode o pipeline completo; confira a chave em `verify-image-signature.yaml` |
| Kyverno: "server gave HTTP response to HTTPS client" | admission controller sem `allowInsecureRegistry`/`hostAliases` ou sem a porta 8080 no Service do ingress | `make kyverno` |
| Kyverno/kubelet: `UNAUTHORIZED ... action: pull` | projeto `poc-devops` do Harbor está privado | torne o projeto **Public** (seção 5.1) |
| ReplicaSet não cria pods após corrigir a causa | backoff do controller | `kubectl delete rs -n poc-app -l app.kubernetes.io/name=poc-devops-api` |
| ArgoCD `Unknown`/`ComparisonError` (*authentication required*) | repositório privado sem credencial cadastrada no ArgoCD (perdida após `make down`), ou sem internet | seção 5.5 |
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

- **Segredos em texto** nos values e `Secret` no `values.yaml` (em produção: Sealed Secrets/SOPS/Vault).
- **Harbor sem TLS e com projeto público**; a proteção da imagem é a assinatura Cosign exigida pelo Kyverno.
- O **ArgoCD lê o repositório no GitHub** (única dependência externa, além de baixar imagens); repositório privado exige token (seção 5.5).
- O runner em container monta o **socket do Docker** do host (equivale a root).
- **Sem NetworkPolicies**; o Alertmanager está ativo, mas **sem canal de notificação**.
- A análise do canary **passa quando não há tráfego** e conta as sondas de saúde nas métricas.

Detalhes e roadmap em [docs/RELATORIO.md](docs/RELATORIO.md).
