# Relatório Técnico – POC Kubernetes Local DevOps

## 1. Decisões técnicas

| Decisão | Motivo |
|---|---|
| **kind** (3 nós) | Leve, rápido de recriar, suporta ingress via `extraPortMappings` |
| **Harbor** | Registry completo com Trivy integrado e UI; simula um registry corporativo |
| **GitHub Actions self-hosted** | Pipeline como código; o runner executa na máquina local, com acesso direto ao Harbor/Sonar locais |
| **Tag = SHA do commit** | Imutável e rastreável; evita sobrescrever `v1.0.0` e garante que o ArgoCD enxergue mudança |
| **Trivy antes do push** | Imagem vulnerável nunca chega ao registry |
| **Cosign por digest + Kyverno `ImageValidatingPolicy`** | Garante que só imagens geradas pelo pipeline rodam no cluster |
| **GitOps (ArgoCD)** | O pipeline não acessa o cluster; ele apenas altera o Git (estado desejado), com `selfHeal` e auditoria |
| **Argo Rollouts (canary)** | Entrega progressiva 10→25→50→100% com rollback rápido via Ingress NGINX |
| **kube-prometheus-stack + Loki/Promtail** | Métricas, dashboards, alertas e logs integrados no Grafana |
| **Makefile como ponto único** | Reprodutível, idempotente, versões fixas, simples de explicar |
| **Versões fixas** | Charts e manifests pinados para que o ambiente funcione igual no futuro |

## 2. Dificuldades encontradas

- **Registry HTTP + containerd:** os nós do kind não resolviam `harbor.local:8080`; solução com `hosts.toml` apontando ao ClusterIP do ingress.
- **Cosign em registry sem TLS:** exigiu `--allow-insecure-registry`, formato clássico de assinatura (`.sig`) e `--allowInsecureRegistry` + `hostAliases` no admission controller do Kyverno.
- **Tag de imagem fixa:** o cálculo de semver nunca criava a tag git, então a imagem era sempre `v1.0.0` e o deploy nunca disparava → migrado para SHA.
- **ConfigMap/Secret não consumidos:** o Rollout não tinha `envFrom` → corrigido, com checksum para reiniciar pods quando mudam.
- **Configuração duplicada/divergente** (script de bootstrap vs Makefile) → unificado no Makefile.
- **Consumo de memória** de SonarQube/Harbor em máquina local → `resources` e JVM ajustados.

## 3. Melhorias para uma versão futura

- Gerenciamento de segredos (Sealed Secrets / SOPS / Vault) e TLS (cert-manager) no Harbor e nos ingresses
- Substituir ingress-nginx (aposentado pelo projeto Kubernetes) pela Gateway API
- `AnalysisTemplate` no Argo Rollouts: rollback automático por taxa de erro/latência (Prometheus)
- Alertas de SLO (taxa de erro 5xx e latência P95) sobre as métricas HTTP já expostas pela app
- SBOM (Syft) e attestations; assinatura *keyless*
- NetworkPolicies, PodSecurity `restricted`, Kyverno em modo mais amplo
- Persistência/HA para Loki e Prometheus; Alertmanager com notificação real (e-mail/Slack)
- Validação do chart com `kubeconform` e ambientes dev/prd
