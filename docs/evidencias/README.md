# Evidências

Salve os prints nesta pasta com os nomes abaixo e marque o que já foi feito.

| # | Evidência | Arquivo | Feito |
|---|---|---|---|
| 1 | `kubectl get nodes -o wide` e `kubectl get pods -A` | 01-cluster.png | [ ] |
| 2 | Pipeline GitHub Actions com os 4 jobs verdes | 02-pipeline.png | [ ] |
| 3 | SonarQube: projeto `poc-devops-api` analisado | 03-sonarqube.png | [ ] |
| 4 | Log do Trivy (scan da imagem) | 04-trivy.png | [ ] |
| 5 | Harbor: imagem + assinatura cosign (`.sig`) | 05-harbor.png | [ ] |
| 6 | ArgoCD: Application `Synced/Healthy` | 06-argocd.png | [ ] |
| 7 | Canary: `kubectl argo rollouts get rollout ... --watch` | 07-canary.png | [ ] |
| 8 | `curl app.local:8080/` com `secret_loaded: true` | 08-app.png | [ ] |
| 9 | Kyverno bloqueando `nginx:latest` | 09-kyverno-latest.png | [ ] |
| 10 | Kyverno bloqueando imagem não assinada | 10-kyverno-cosign.png | [ ] |
| 11 | Dashboard Grafana da API | 11-grafana.png | [ ] |
| 12 | Grafana Explore → Loki (logs da app) | 12-loki.png | [ ] |
| 13 | Prometheus: regra/alerta `PocAppPodDown` | 13-alerta.png | [ ] |
| 14 | HPA escalando sob carga | 14-hpa.png | [ ] |
| 15 | Rollback (`abort` ou `git revert`) | 15-rollback.png | [ ] |
