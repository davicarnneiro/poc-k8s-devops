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

Recursos: **~12 GB de RAM livres e 6 CPUs** (SonarQube e Harbor são pesados). Linux. Você também precisa de uma **conta no GitHub**.

## 3. Guia de execução

Siga as fases **na ordem**. Cada uma termina com um **✅ Checkpoint**: só avance quando ele for atingido.

| Fase | O que você faz | Ao final você tem |
|---|---|---|
| **0. Seu repositório** | fork, Actions, `repoURL` | um repositório seu, com permissão de escrita |
| **1. A máquina** | `/etc/hosts`, Docker, chave do Cosign | máquina pronta |
| **2. A plataforma** | `make all` | cluster com Harbor, SonarQube, ArgoCD, Kyverno, Rollouts, Prometheus, Grafana e Loki |
| **3. O CI/CD** | projeto no Harbor, token do Sonar, secrets, runner | pipeline pronto para rodar |
| **4. O primeiro deploy** | pipeline e canary | aplicação no ar, assinada, entregue por GitOps |
| **5. A validação** | `make smoke-test` e provas manuais | 13 verificações passando |

Se algo falhar, veja o [Troubleshooting](#6-troubleshooting).

---

### Fase 0 — Seu repositório

O pipeline **faz commit da tag da imagem** no repositório, e o ArgoCD lê esse mesmo repositório. Por isso você precisa de um repositório **seu**,
com permissão de escrita, **antes** de rodar o `make all` (que já executa o `make app`).

1. Faça um **fork** deste repositório no GitHub e clone o **seu fork** (não o original).
2. No fork, no seu repositorio, vai na aba **Actions** e habilite os workflows (em forks eles vêm desativados).
3. Aponte o ArgoCD para o seu fork, trocando o `repoURL` em `infra/argocd/application.yaml`:

```bash
sed -i 's#davicarnneiro/poc-k8s-devops#SEU_USUARIO/poc-k8s-devops#' infra/argocd/application.yaml
git commit -am "chore: aponta o ArgoCD para o meu fork [skip ci]" && git push origin main
```

> [!TIP]
> Se o fork for **público**, o ArgoCD lê o repositório sem credencial. Se for privado, veja a **Fase 3.5**.

**✅ Checkpoint:** `grep repoURL infra/argocd/application.yaml` mostra o **seu** usuário, e a aba *Actions* do fork está habilitada.

---

### Fase 1 — A máquina

**1.1 `/etc/hosts`.** Todos os serviços usam `*.local` na porta 8080. Esse passo é **necessário nesta configuração**: todos compartilham a mesma porta e o
Ingress NGINX escolhe o serviço pelo **nome do host** (`http://localhost:8080` devolve 404). O nome `harbor.local:8080` também faz parte do endereço das
imagens, usado pelo `docker push`, pela assinatura do Cosign e pela política do Kyverno.

```bash
grep -q "harbor.local" /etc/hosts || echo "127.0.0.1 harbor.local sonar.local argocd.local grafana.local prometheus.local app.local" | sudo tee -a /etc/hosts
```

**1.2 Docker aceitar o Harbor sem TLS.** Em `/etc/docker/daemon.json` (se o arquivo já existir, acrescente só a chave):

```json
{ "insecure-registries": ["harbor.local", "harbor.local:8080"] }
```

```bash
sudo systemctl restart docker
```

**1.3 Par de chaves do Cosign** (senha **vazia**, apenas Enter). O pipeline assina com a chave privada, e o Kyverno verifica com a pública:

```bash
cosign generate-key-pair      # gera cosign.key e cosign.pub
mkdir -p .cosign && mv cosign.key .cosign/   # .cosign/ está no .gitignore
cp cosign.pub infra/cosign/cosign.pub
```

Cole o conteúdo de `cosign.pub` no campo `attestors[].cosign.key.data` de `infra/kyverno/verify-image-signature.yaml`.

> [!WARNING]
> **Nunca versione `cosign.key`.** Ela vira o secret `COSIGN_PRIVATE_KEY` na Fase 3.

**✅ Checkpoint:**

```bash
make hosts-check                    # ✅ /etc/hosts ok
docker info | grep -A3 "Insecure"   # lista harbor.local:8080
git status --short                  # mostra cosign.pub e verify-image-signature.yaml modificados
```

---

### Fase 2 — A plataforma

```bash
make all
```

Ele verifica o `/etc/hosts` e depois sobe, **na ordem certa** e de forma idempotente (pode repetir sem problema): cluster kind, Ingress NGINX e
Metrics Server (`up`) → Argo Rollouts → Harbor, SonarQube, Kyverno e ArgoCD (`platform`) → políticas Kyverno → Prometheus, Grafana, Loki e dashboard
(`observability`) → Application do ArgoCD (`app`) → credenciais.

> [!IMPORTANT]
> **Logo depois do `make all`, o aplicativo ainda não está no ar, e isso é o esperado.** A imagem só existe depois que o projeto do Harbor for criado
> (Fase 3) e o pipeline rodar (Fase 4). Até lá:
>
> | O que você vê | Por quê |
> |---|---|
> | `app.local:8080` responde **503** | ainda não há pods da aplicação |
> | Rollout `Degraded` e ArgoCD `Synced`/`Degraded` | o `values.yaml` aponta para uma imagem que não está no Harbor |
> | o Kyverno **nega** os pods | o projeto `poc-devops` ou a imagem ainda não existem |

Endereços e credenciais (também em `make credentials`):

| Serviço | URL | Login |
|---|---|---|
| Harbor | http://harbor.local:8080 | `admin` / `Harbor@12345` |
| SonarQube | http://sonar.local:8080 | `admin` / `admin` (troca no 1º login) |
| ArgoCD | http://argocd.local:8080 | `admin` / senha de `make credentials` |
| Grafana | http://grafana.local:8080 | `admin` / `admin` |
| Prometheus | http://prometheus.local:8080 | — |
| Aplicação | http://app.local:8080 | — |

**✅ Checkpoint:**

```bash
make status         # todos os pods Running ou Completed (a aplicação ainda não aparece)
make credentials    # mostra as URLs e a senha do ArgoCD
```

<details>
<summary><b>Prefere executar por partes? (útil para explicar e depurar)</b></summary>

Cada passo depende do anterior:

```bash
make up              # 1. Cluster kind, Ingress NGINX, Metrics Server
make rollouts        # 2. Argo Rollouts (CRD Rollout usada pelo chart)
make platform        # 3. Harbor, SonarQube, Kyverno, ArgoCD (+ configura o containerd dos nós para o Harbor)
make policies        # 4. Políticas Kyverno no namespace poc-app (precisa do Kyverno pronto)
make observability   # 5. Prometheus, Grafana, Alertmanager, Loki/Promtail e dashboard da API
make app             # 6. Registra o Application no ArgoCD (GitOps)
make credentials     # 7. Mostra URLs e senhas
```

O `make up` sozinho cria só o cluster base, o que ajuda a validar o ingress antes do resto.

</details>

> [!NOTE]
> Se recriar o cluster, rode `make all` de novo: o ClusterIP do ingress muda e os nós precisam ser reconfigurados.

---

### Fase 3 — O CI/CD

**3.1 Projeto no Harbor.** O projeto `poc-devops` (**público**) precisa existir **antes do pipeline**, porque o job 3 faz push nele:

```bash
make harbor-project   # idempotente; se falhar, aguarde o Harbor ficar pronto (kubectl get pods -n harbor)
```

Pela interface: http://harbor.local:8080 → *Projects → New Project* → `poc-devops`, **Access Level: Public**. (Projeto privado exigiria `imagePullSecret` e
credenciais no Kyverno; para a POC usamos público, e a segurança fica por conta da assinatura Cosign exigida pelo Kyverno.)

**3.2 Token do SonarQube.** Em http://sonar.local:8080 entre com `admin` / `admin` (o SonarQube pede para trocar a senha) e gere um token em
*My Account → Security → Generate Token*.

**3.3 Secrets do GitHub** (no seu fork: *Settings → Secrets and variables → Actions*):

| Secret | Valor |
|---|---|
| `SONAR_TOKEN` | token do passo 3.2 |
| `HARBOR_USER` / `HARBOR_PASSWORD` | `admin` / `Harbor@12345` |
| `COSIGN_PRIVATE_KEY` | conteúdo de `.cosign/cosign.key` |

Em *Settings → Actions → General → Workflow permissions*, escolha **Read and write** (o pipeline faz commit da tag).

**3.4 Runner self-hosted.** O pipeline roda na sua máquina, por um runner registrado no seu fork. A forma mais simples é **subir o runner em um container Docker**
(a usada nas evidências):

1. No GitHub: *Settings → Actions → Runners → New self-hosted runner* (Linux x64). Na tela, copie **só o token** (o valor depois de `--token`
   no comando `./config.sh`). Ele vale ~1 h e **só serve para registrar** o runner.
2. Suba o container, trocando `SEU_USUARIO` e `<TOKEN>`:

```bash
docker run -d --name github-runner --network host \
  --add-host harbor.local:127.0.0.1 --add-host sonar.local:127.0.0.1 \
  -e REPO_URL="https://github.com/SEU_USUARIO/poc-k8s-devops" \
  -e RUNNER_NAME="local-ubuntu-runner" -e RUNNER_TOKEN="<TOKEN>" -e RUNNER_WORKDIR="/tmp/runner" \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -v /usr/local/bin/cosign:/usr/local/bin/cosign:ro \
  -v /usr/local/bin/helm:/usr/local/bin/helm:ro \
  myoung34/github-runner:latest
```

3. Confira: `docker logs github-runner` deve terminar em `Listening for Jobs`, e o runner aparece **Idle** na tela do GitHub.

O que cada parte faz:

| Trecho | Para quê |
|---|---|
| `--network host` | o runner alcança `harbor.local:8080` e `sonar.local:8080` pela máquina |
| `--add-host ...:127.0.0.1` | o container tem o próprio `/etc/hosts`, que não enxerga o da máquina |
| `-v /var/run/docker.sock` | o pipeline faz `docker build` e `docker push` usando o Docker da máquina |
| `-v .../cosign` e `-v .../helm` | o runner usa o `cosign` 3.x e o `helm` da máquina; confira o caminho com `which cosign helm` e ajuste se não for `/usr/local/bin` |

> [!WARNING]
> **Sem `--restart`, de propósito.** A cada início o container se registra de novo com o `RUNNER_TOKEN`; como o token expira em ~1 h, um reinício
> automático (reboot da máquina, reinício do Docker) faria o registro falhar com **404** e o container ficaria em laço de reinícios. Se ele parar,
> **recrie** com um token novo: `docker rm -f github-runner` e o `docker run` acima. Ao terminar de usar, remova o container e a entrada do runner em
> *Settings → Actions → Runners*.

Esse runner monta o socket do Docker da máquina, o que equivale a acesso root a ela: use apenas em ambiente local de testes.

<details>
<summary><b>Alternativa: runner direto na máquina, sem container</b></summary>

Na mesma tela *New self-hosted runner*, siga os comandos exibidos (`./config.sh ...` e `./run.sh`). Nesse caso a própria máquina precisa ter
`docker`, `helm`, `cosign` 3.x, `python3` (com `venv`) e `git`, além dos hosts `*.local` no `/etc/hosts` (Fase 1.1).

</details>

**3.5 ArgoCD e repositório privado.** O ArgoCD faz o `git pull` do repositório definido no `repoURL` (Fase 0).

- **Repositório público:** nada a fazer.
- **Repositório privado:** é preciso cadastrar uma credencial, que vive no cluster e **precisa ser refeita a cada `make down`**.

<details>
<summary><b>Como cadastrar a credencial de um repositório privado</b></summary>

1. Gere um *Personal Access Token* no GitHub (*Settings → Developer settings → Personal access tokens*), com permissão de **leitura** do conteúdo do
   repositório (fine-grained: *Contents: Read-only*).
2. Cadastre-o no ArgoCD, por uma das duas formas.

*Pela interface* (http://argocd.local:8080): *Settings → Repositories → Connect Repo* → método **HTTPS**, *Repository URL* igual ao `repoURL`, *Username*
o seu usuário do GitHub e *Password* o token.

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

O token é um segredo: não o versione.

</details>

**✅ Checkpoint:**

- No GitHub, *Settings → Actions → Runners* mostra o runner **Idle**.
- *Settings → Secrets* lista os 4 secrets (`SONAR_TOKEN`, `HARBOR_USER`, `HARBOR_PASSWORD`, `COSIGN_PRIVATE_KEY`).
- O projeto existe no Harbor: `curl -s "http://harbor.local:8080/api/v2.0/projects?name=poc-devops"` devolve um JSON com `poc-devops`.

---

### Fase 4 — O primeiro deploy

**4.1 Rode o pipeline:** no seu fork, *Actions → CI/CD → Run workflow* (branch `main`). Depois, qualquer push na `main` também o dispara. São 4 jobs:

| Job | O que faz |
|---|---|
| 1. Lint, testes e SonarQube | `helm lint`/`helm template`, pytest com cobertura e SAST; **falha** se o Quality Gate reprovar |
| 2. Build e Trivy | build multi-stage; falha se houver vulnerabilidade CRITICAL/HIGH com correção disponível |
| 3. Push e Cosign | envia ao Harbor e assina o digest |
| 4. GitOps | atualiza `image.tag` no `values.yaml` (tag = SHA curto do commit, **imutável** e rastreável até o commit) |

**4.2 Traga o commit do bot** antes de qualquer push seu (o job 4 commita no `main`):

```bash
git pull --rebase origin main
```

**4.3 Acompanhe o canary.** O ArgoCD detecta o commit e o Argo Rollouts libera a versão em 10% (2 min) → 25% (5 min) → 50% (10 min) → 100%:

```bash
make rollouts-cli      # (uma vez) instala o plugin 'kubectl argo rollouts'
kubectl argo rollouts get rollout poc-devops-api -n poc-app --watch
```

Para não esperar os ~17 min, promova o canary de uma vez:

```bash
kubectl argo rollouts promote poc-devops-api -n poc-app --full
```

> [!WARNING]
> O `--full` **pula a análise automática**. Use-o só em versões que você sabe que estão boas, como neste primeiro deploy.

Se o ReplicaSet continuar sem criar pods depois de o pipeline terminar, force uma nova tentativa:
`kubectl delete rs -n poc-app -l app.kubernetes.io/name=poc-devops-api`.

**✅ Checkpoint:**

```bash
curl http://app.local:8080/        # {"service":"poc-devops-api", ..., "secret_loaded":true}
kubectl get application -n argocd  # Synced/Healthy
```

O Rollout aparece `Healthy` (100%) e o `secret_loaded: true` mostra que o ConfigMap e o Secret chegaram à aplicação.

---

### Fase 5 — A validação

**5.1 Smoke test.** Publique uma vez a imagem de teste **sem assinatura** (ela prova que a política do Cosign barra imagens não assinadas) e rode as verificações:

```bash
make unsigned-image   # uma vez (já cria o projeto no Harbor, se faltar)
make smoke-test       # esperado: 13 ok, 0 falha(s)
```

Ele verifica nós, app, métricas, ArgoCD, Rollout, HPA, as duas políticas do Kyverno (validando a **causa** da negação: `:latest` e `no signatures found`),
Prometheus (target e regras), Grafana e Loki, e retorna erro se algo falhar.

**5.2 Provas manuais** (para demonstrar):

```bash
# Política 1: :latest é bloqueado
kubectl run teste --image=nginx:latest -n poc-app
#   → Error ... Imagens com tag ':latest' ... sao proibidas

# Política 2: imagem REAL, mas sem assinatura, é bloqueada (os limits no --overrides evitam que a outra política barre antes)
kubectl run teste -n poc-app --image=harbor.local:8080/poc-devops/nao-assinada:1.0 \
  --overrides='{"spec":{"containers":[{"name":"teste","image":"harbor.local:8080/poc-devops/nao-assinada:1.0","resources":{"limits":{"cpu":"100m","memory":"64Mi"}}}]}}'
#   → Error ... A imagem deve estar assinada ... no signatures found

# A imagem do pipeline tem assinatura válida (a tag está em chart/poc-devops-api/values.yaml)
cosign verify --key infra/cosign/cosign.pub --allow-insecure-registry \
  harbor.local:8080/poc-devops/poc-devops-api:<TAG>

# Aplicação, GitOps e HPA
curl http://app.local:8080/healthz
curl http://app.local:8080/metrics | head
kubectl get hpa,pods,ingress -n poc-app
```

Para ver o HPA escalar, gere carga dentro do cluster (os limits no `--overrides` são exigidos pela política do Kyverno) e acompanhe em outro terminal:

```bash
kubectl run load -n poc-app --image=busybox:1.36 --restart=Never --overrides='{"spec":{"containers":[{"name":"load","image":"busybox:1.36","command":["sh","-c","while true; do wget -q -O- http://poc-devops-api/ >/dev/null; done"],"resources":{"limits":{"cpu":"100m","memory":"64Mi"}}}]}}'
kubectl get hpa -n poc-app -w        # as réplicas sobem de 2 até no máximo 5
kubectl delete pod load -n poc-app   # ao terminar
```

**Observabilidade:**

| O que | Onde |
|---|---|
| Métricas | Grafana http://grafana.local:8080 → dashboard *POC DevOps API - Golden Signals & Resources* |
| Logs | Grafana → *Explore* → Loki → `{namespace="poc-app"}` |
| Alertas | Prometheus http://prometheus.local:8080 → *Status › Rule health* → buscar `PocApp` |

**✅ Checkpoint:** `make smoke-test` termina com **`13 ok, 0 falha(s)`**.

Quer ver o rollback automático em ação? Ele é opcional e está na [seção 4](#4-rollback).

---

## 4. Rollback

**Rollback automático (canary com análise)** — o Argo Rollouts consulta o Prometheus durante o canary
(`chart/.../analysistemplate.yaml`). Se a taxa de sucesso do canary ficar **< 95%** ou a latência P95 **> 500 ms**, o deploy é
**abortado sozinho** e 100% do tráfego volta para a versão estável. Sem tráfego, a análise passa (não trava deploys sem carga).

Demonstração (a app tem uma taxa de erro simulada, `APP_ERROR_RATE`, controlada por `config.errorRate` no values):

```bash
# 1. Terminal A: gerar tráfego contínuo (ANTES do push; sem tráfego a análise não vê nada)
while true; do
  curl -s -o /dev/null -w "%{http_code} " http://app.local:8080/
  sleep 0.2
done

# 2. Terminal B: acompanhar o canary
kubectl argo rollouts get rollout poc-devops-api -n poc-app --watch

# 3. Provocar a falha: em chart/poc-devops-api/values.yaml troque  errorRate: "0"  por  "1"
git commit -am "test: simula erros para demo de rollback automatico [skip ci]" && git push
#    O ConfigMap muda -> novo ReplicaSet -> canary 10% -> AnalysisRun falha -> Rollout abortado (Degraded),
#    tráfego volta 100% à versão estável.

# 4. Voltar ao normal: errorRate: "0" de novo
git commit -am "revert: remove erros simulados [skip ci]" && git push
```

> [!TIP]
> O Terminal A deve mostrar `200` e, durante o canary, alguns `500`; quando o rollout é abortado, os `500` somem. Se colar o loop em uma linha só no zsh,
> o `;` depois da URL pode ser escapado: digite em linhas separadas, como acima. **Não use `promote` nem `abort` durante a demonstração.**

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

## 5. Referência do Makefile

`make help` lista os alvos. Os principais:

| Comando | O que faz |
|---|---|
| `make all` | sobe **todo** o ambiente (Fase 2) |
| `make up` | só o cluster base: kind, Ingress NGINX e Metrics Server |
| `make harbor-project` | cria o projeto `poc-devops` (público) no Harbor; idempotente |
| `make unsigned-image` | publica a imagem de teste **sem assinatura** (já cria o projeto) |
| `make smoke-test` | valida o ambiente de ponta a ponta (13 verificações) |
| `make credentials` | mostra URLs e senhas |
| `make status` | nós e pods de todos os namespaces |
| `make rollouts-cli` | (opcional) plugin `kubectl argo rollouts` no host |
| `make configure-kind-registry` | reconfigura os nós para o Harbor (use após reiniciar o PC) |
| `make down` | **remove o cluster** (apaga todos os dados e componentes); para recriar do zero: `make down && make all` |

## 6. Troubleshooting

| Sintoma | Causa provável | Solução |
|---|---|---|
| `ImagePullBackOff` do Harbor (`not found`/`404`) | nós do kind sem a resolução de `harbor.local` (a entrada no `/etc/hosts` do nó se perde ao reiniciar o PC/containers, ou o ClusterIP do ingress mudou) | `make configure-kind-registry` e depois `kubectl delete pod -n poc-app -l app.kubernetes.io/name=poc-devops-api` |
| `docker push` → "http: server gave HTTP response" | falta `insecure-registries` | Fase 1.2 e reiniciar o Docker |
| Pod negado: "imagem deve estar assinada" | imagem não assinada, ou `cosign.pub` da política difere da chave usada | rode o pipeline completo; confira a chave em `verify-image-signature.yaml` (Fase 1.3) |
| Kyverno: "server gave HTTP response to HTTPS client" | admission controller sem `allowInsecureRegistry`/`hostAliases` ou sem a porta 8080 no Service do ingress | `make kyverno` |
| Kyverno/kubelet: `UNAUTHORIZED ... action: pull` | projeto `poc-devops` do Harbor está privado | torne o projeto **Public** (Fase 3.1) |
| Kyverno: `UNAUTHORIZED: project poc-devops not found` | o Harbor recriado ainda não tem o projeto | `make harbor-project` (Fase 3.1) |
| ReplicaSet não cria pods após corrigir a causa | backoff do controller | `kubectl delete rs -n poc-app -l app.kubernetes.io/name=poc-devops-api` |
| ArgoCD `Unknown`/`ComparisonError` (*authentication required*) | repositório privado sem credencial cadastrada no ArgoCD (perdida após `make down`), ou `repoURL` errado, ou sem internet | Fase 0 e Fase 3.5 |
| ArgoCD: `no matches for kind "Rollout"` | CRD do Rollouts ausente | `make rollouts` |
| App `Degraded` / 503 logo após instalar | a tag do `values.yaml` ainda não existe no Harbor | rode o pipeline uma vez (Fase 4) |
| HPA `<unknown>` | metrics-server sem `--kubelet-insecure-tls` | `make metrics-server` |
| Sonar: "Not authorized" | `SONAR_TOKEN` ausente/errado | Fase 3.2 e 3.3 |
| Pipeline falha no `git push` (403) | permissão de escrita do workflow | Fase 3.3 |
| Runner em container reiniciando sem parar (`runner-registration` → 404) | o `RUNNER_TOKEN` expirou (vale ~1 h) e o container tenta se registrar de novo | `docker rm -f github-runner` e recrie com um token novo (Fase 3.4) |
| `make all` para em `hosts-check` | faltam entradas no `/etc/hosts` | Fase 1.1 |
| Pods `Pending` | falta de memória | feche apps; reduza `jvmOpts` do SonarQube |

## 7. Estrutura do repositório

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

## 8. Limitações conhecidas (POC)

- **Segredos em texto** nos values e `Secret` no `values.yaml` (em produção: Sealed Secrets/SOPS/Vault).
- **Harbor sem TLS e com projeto público** (leitura anônima, sem escrita); a proteção da imagem é a assinatura Cosign exigida pelo Kyverno. As portas do ingress (8080/8443) são publicadas **só em `127.0.0.1`**, então os serviços não ficam acessíveis pela rede local.
- O **ArgoCD lê o repositório no GitHub** (única dependência externa, além de baixar imagens); repositório privado exige token (Fase 3.5).
- O runner em container monta o **socket do Docker** do host (equivale a root).
- **Sem NetworkPolicies**; o Alertmanager está ativo, mas **sem canal de notificação**.
- A análise do canary **passa quando não há tráfego** e conta as sondas de saúde nas métricas.

Detalhes e roadmap em [docs/RELATORIO.md](docs/RELATORIO.md).
