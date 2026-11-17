# Relatório Técnico – POC Kubernetes Local DevOps

## Resumo

- **O que foi feito:** um ciclo completo de entrega, 100% local (kind, Harbor, GitHub Actions self-hosted): testes, SonarQube e Trivy no pipeline, imagem assinada com Cosign, deploy por GitOps (ArgoCD), canary com Argo Rollouts, políticas Kyverno e observabilidade (Prometheus, Grafana, Loki). Sobe com `make all`.
- **Diferenciais entregues:** Cosign, ArgoCD, Canary com **rollback automático** (análise no Prometheus) e alertas.
- **Decisão central:** o pipeline nunca acessa o cluster; ele só altera o Git (a tag da imagem, o SHA do commit) e o ArgoCD aplica. O Kyverno garante que só roda imagem assinada pelo pipeline.
- **Maior dificuldade:** o registry local sem TLS. Nós do kind, Kyverno e Cosign precisavam alcançar e confiar no `harbor.local:8080`, e cada um falhou por um motivo diferente (seção 2).
- **Principais melhorias futuras:** segredos e TLS de verdade, assinatura *keyless*, Gateway API em vez do ingress-nginx e versionamento semântico (seção 3).

Detalhes: decisões (seção 1), dificuldades (seção 2) e melhorias (seção 3). Provas de funcionamento em [evidencias/](evidencias/README.md).

## 1. Decisões técnicas

| Decisão | Motivo |
|---|---|
| **kind** (3 nós) | Leve, rápido de recriar, suporta ingress via `extraPortMappings` |
| **Harbor** | Registry completo com Trivy integrado e UI; simula um registry corporativo |
| **GitHub Actions self-hosted** | Pipeline como código; o runner executa na máquina local, com acesso direto ao Harbor/Sonar locais |
| **Tag = SHA do commit** | Imutável e rastreável; evita sobrescrever `v1.0.0` e garante que o ArgoCD enxergue mudança |
| **Trivy antes do push** | Imagem vulnerável nunca chega ao registry |
| **SonarQube com Quality Gate bloqueante** | O pipeline falha se o gate reprovar (cobertura de código e issues no código novo) |
| **Cosign por digest + Kyverno `ImageValidatingPolicy`** | Garante que só imagens geradas pelo pipeline rodam no cluster |
| **Projeto Harbor público + assinatura obrigatória** | Evita credenciais de pull no Kyverno e nos nós; a segurança fica na assinatura exigida na admissão |
| **GitOps (ArgoCD)** | O pipeline não acessa o cluster; ele apenas altera o Git (estado desejado), com `selfHeal` e auditoria |
| **Argo Rollouts (canary) + AnalysisTemplate** | Entrega progressiva 10→25→50→100% via Ingress NGINX, com análise no Prometheus (sucesso ≥ 95%, P95 ≤ 500 ms) e **rollback automático** |
| **HPA controla as réplicas (`minReplicas: 2`)** | O chart não define `replicas` para não disputar com o HPA; 2 réplicas dão redundância durante o canary |
| **Chart só com Rollout** | Removido o suporte a `Deployment` que não tinha template: menos código morto para manter e explicar |
| **Erro simulado determinístico (`APP_ERROR_RATE`)** | Permite demonstrar o rollback automático de forma repetível, sem aleatoriedade |
| **kube-prometheus-stack + Loki/Promtail** | Métricas, dashboards, alertas e logs integrados no Grafana |
| **`make smoke-test`** | 13 verificações automáticas; as de política validam a **causa** da negação, e não só o fato de ter sido negado |
| **Makefile como ponto único** | Reprodutível, idempotente, versões fixas, simples de explicar |
| **Versões fixas** | Charts e manifests pinados para que o ambiente funcione igual no futuro |

## 2. Dificuldades encontradas

### Registry local sem TLS e acesso a partir do cluster

| Problema | Causa | Solução |
|---|---|---|
| Nós do kind em `ImagePullBackOff` (`not found`) | O `hosts.toml` do containerd apontava para o IP do ingress, então a requisição saía com `Host: <IP>` e o Ingress do Harbor só responde a `harbor.local` (404) | Cada nó resolve `harbor.local` pelo próprio `/etc/hosts` e usa `http://harbor.local:8080`; porta 8080 exposta no Service do ingress (`make configure-kind-registry`) |
| Kyverno: `server gave HTTP response to HTTPS client` | O chart já vem com `--allowInsecureRegistry=false`; um patch condicional meu achou o texto no argumento e foi pulado | Opção nativa `features.registryClient.allowInsecure: true` nos values + `hostAliases` do `harbor.local` no admission controller |
| Kyverno/kubelet: `UNAUTHORIZED ... action: pull` | O projeto do Harbor estava privado e ninguém tinha credenciais | Projeto `poc-devops` público; a segurança fica na assinatura Cosign obrigatória |
| `ImagePullBackOff` após reiniciar o PC | O `/etc/hosts` de um nó do kind se perde quando o container reinicia | Repetir `make configure-kind-registry` (documentado no troubleshooting) |
| Cosign não assinava em registry HTTP | Registry sem TLS | `--allow-insecure-registry` e formato clássico de assinatura (`.sig`) |

### Políticas e supply chain

| Problema | Causa | Solução |
|---|---|---|
| Política de assinatura rejeitada na criação | Em CEL, `attestors.cosign-key` é lido como `attestors.cosign - key` (subtração) | Attestor renomeado para `cosign`, sem hífen |
| Pod de teste barrado pela política errada | A política de `resources.limits` também se aplica ao pod de teste e atua antes | O pod de teste declara limits via `--overrides`, isolando a verificação de assinatura |

### Pipeline e qualidade de código

| Problema | Causa | Solução |
|---|---|---|
| 401 no SonarQube | `SONAR_TOKEN` ausente/inválido (o servidor exige token até para baixar o JRE do scanner) | Novo token de usuário e atualização do secret do GitHub |
| Quality Gate reprovado (`new_violations = 1`) | Regra `python:S8415`: o `HTTPException(500)` do endpoint não estava documentado em `responses=` | Resposta 500 documentada no endpoint |
| Runner em container não alcançava os serviços | O container tem o próprio `/etc/hosts` | `--add-host harbor.local:127.0.0.1` e `sonar.local:127.0.0.1` |

### Aplicação, GitOps e observabilidade

| Problema | Causa | Solução |
|---|---|---|
| `secret_loaded: false` | O Rollout não tinha `envFrom` para o ConfigMap e o Secret | `envFrom` + checksum nas anotações para reiniciar os pods quando eles mudam |
| Grafana em `CrashLoopBackOff` | Dois datasources marcados como padrão: o chart `loki-stack` cria o seu com `isDefault: true` | `loki.isDefault: false` |
| Timeouts de pull de imagem no primeiro `make all` | Instabilidade de rede ao baixar muitas imagens ao mesmo tempo | Timeouts de 300 s; o `make` é idempotente e pode ser repetido |

## 3. Melhorias para uma versão futura

- **Segredos e TLS:** Sealed Secrets / SOPS / Vault; cert-manager no Harbor e nos ingresses; Harbor privado com `imagePullSecret` e credenciais no Kyverno
- **Ingress:** substituir o ingress-nginx (aposentado pelo projeto Kubernetes) pela Gateway API
- **Análise do canary:** excluir as sondas (`/healthz`) das métricas, exigir um tráfego mínimo antes de promover e considerar também logs (Loki)
- **Alertas:** notificação real no Alertmanager (e-mail/Slack) e SLOs com *burn rate*
- **Logs:** migrar do `loki-stack` (descontinuado) para o chart do Loki 3.x, resolvendo o aviso de volume no Grafana
- **Versionamento:** versão semântica (`vX.Y.Z`) nas imagens e no chart, gerada por tags git ou por *conventional commits*, além do SHA
- **Supply chain:** SBOM (Syft), attestations e assinatura *keyless*
- **Segurança do cluster:** NetworkPolicies, PodSecurity `restricted`, Kyverno em modo mais amplo
- **Resiliência:** persistência e HA para Loki e Prometheus
- **Qualidade:** validação do chart com `kubeconform` e ambientes dev/prd
