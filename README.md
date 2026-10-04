# k8s-homelab — Kubernetes-кластер в WSL с полной автоматизацией

Решение разворачивает в WSL2 (Ubuntu-24.04) kubeadm-кластер с приложением,
Gateway API (Envoy), балансировщиком (MetalLB), мониторингом (kube-prometheus-stack),
сбором логов (Filebeat) и полным CI/CD (GitHub Actions + Flux GitOps).

## Архитектура

```
GitHub (Nikkri112/hello-app)
   │  git push в main (app/ или Dockerfile)
   ▼
GitHub Actions CI: ruff → pytest → docker build → smoke-тест в контейнере
   → push образа в Docker Hub (тег = git sha коммита)
   │  при успехе CI (автоматически)
   ▼
GitHub Actions CD: подставляет тег образа в kustomize, коммит от бота
   │  раз в минуту
   ▼
Flux (в кластере): sync git → kustomize/overlays/wsl
   │
   ▼
Envoy Gateway (Gateway API): HTTPRoute hello-app (HTTP) и grafana.hello-app (HTTPS/TLS)
Prometheus: собирает метрики приложения через ServiceMonitor
Filebeat (daemonset): JSON-логи с k8s-метаданными
```

- Весь свой стек описан декларативно в kustomize (base + overlay WSL); helm-чарты
  (Envoy Gateway, cert-manager, kube-prometheus-stack) ставит `deploy.sh` с фиксированными версиями.
- Flux применяет kustomize-overlay и следит за здоровьем Deployment hello-app (health check в Kustomization).
- Метрики приложения (`app_http_requests_total`, гистограмма задержек) собираются
  Prometheus'ом через ServiceMonitor — лейбл `release: kube-prometheus-stack` обязателен
  (селектор Prometheus из helm-дефолтов).
- Дашборд «hello-app» в Grafana провижинится sidecar'ом автоматически (ConfigMap
  с лейблом `grafana_dashboard: "1"`, sidecar сканирует все namespace).

## Структура

```
├── bootstrap/                     # ОДИН РАЗ на свежей WSL (внутри WSL)
│   ├── 01-wsl-prereqs.sh          # systemd, swap off, mount --make-rshared /
│   ├── 02-install-kubeadm.sh      # containerd, kubeadm/kubelet/kubectl v1.37.1
│   ├── 03-cluster-init.sh         # kubeadm init + flannel CNI
│   ├── 04-install-helm.sh         # helm v3.22.0
│   └── 05-install-flux.sh         # Flux CD: контроллеры + привязка к git-репо
├── manifests/
│   ├── metallb-install/           # вендоренные манифесты MetalLB v0.16.1
│   └── flannel/                   # вендоренный манифест flannel
├── kustomize/
│   ├── base/                      # hello-app (+ServiceMonitor+дашборд), filebeat, MetalLB-пул, TLS-ингресс Grafana
│   └── overlays/wsl/              # слой среды WSL (патч пула под текущую подсеть)
├── helm/
│   ├── values-monitoring.yaml     # values kube-prometheus-stack (дефолты)
│   └── values-gateway.yaml        # values envoy-gateway (дефолты)
├── .github/workflows/             # CI/CD: ci.yml (сборка), cd.yml (GitOps bump тега)
├── tests/                         # pytest-тесты приложения (прогоняются в CI)
├── app/ + Dockerfile              # исходники приложения (Python/gunicorn)
├── deploy.sh                      # ГЛАВНАЯ КНОПКА: развёртывание всего стека
├── verify.sh                      # проверка здоровья всех компонентов
└── deployment.yaml, service.yaml  # оригинальные манифесты (справочно, живут в kustomize/base)
```

## Полное развёртывание с нуля (свежая WSL)

Все bootstrap-скрипты выполняются ВНУТРИ WSL:

```bash
bash bootstrap/01-wsl-prereqs.sh     # затем wsl --shutdown из PowerShell!
bash bootstrap/02-install-kubeadm.sh
bash bootstrap/03-cluster-init.sh    # кластер поднят
bash bootstrap/04-install-helm.sh
bash deploy.sh                       # весь стек: MetalLB, Gateway, приложение, мониторинг, логи
```

## Повторный запуск / повседневное использование

```bash
bash deploy.sh      # идемпотентен; после перезапуска WSL обновит пул MetalLB
bash verify.sh      # проверка здоровья: нода, поды, Gateway, приложение, метрики, логи
```

## CI/CD (GitHub Actions + Flux GitOps)

Пайплайн полностью автоматический:

```
git push в main (app/ или Dockerfile)
  → CI: ruff + pytest → docker build → smoke-тест в контейнере
        → push образа в Docker Hub (тег <git-sha> + latest)
  → CD (запускается сам при успехе CI): подставляет тег в kustomize,
        коммит от github-actions[bot]
  → Flux: применяет в кластер за ~1,5 минуты, поды перекатываются
```

Защита от мусора:
- тесты упали → образ не публикуется, CD не запускается, кластер не трогается;
- CD-коммит меняет только `kustomize/` → CI на него не реагирует (нет цикла);
- PR-ветки: только линт+тесты+сборка, без публикации и деплоя.

Секреты (Settings → Secrets and variables → Actions): `DOCKERHUB_USERNAME`, `DOCKERHUB_TOKEN`
(Personal access token с правами Read & Write).

Первичная привязка Flux к репо (один раз, внутри WSL):

```bash
bash bootstrap/05-install-flux.sh Nikkri112/hello-app main
```

Откат: revert CD-коммита (Flux вернёт предыдущий тег образа) либо
`kubectl rollout undo -n hello-app deploy/hello-app`.

## Что где смотреть

| Что                | Как                                                                     |
|--------------------|-------------------------------------------------------------------------|
| Приложение         | `http://<node-ip>:<nodePort hello-gateway>` — по голому IP, hosts-записи не нужны; порт — `kubectl -n envoy-gateway-system get svc` |
| Grafana (HTTPS)    | hosts: `172.26.20.204 grafana.hello-app` → `https://grafana.hello-app:<nodePort grafana-gateway>` (443:3xxxx). CA из секрета `root-ca-secret` (ns cert-manager) — импортировать в доверенные Windows для зелёного замка |
| Grafana (port-forward) | `kubectl port-forward svc/kube-prometheus-stack-grafana 3000:80 -n monitoring` → http://localhost:3000 (admin / пароль из секрета kube-prometheus-stack-grafana) |
| Prometheus UI      | `kubectl port-forward svc/kube-prometheus-stack-prometheus 9090:9090 -n monitoring` → http://localhost:9090 |
| Логи приложения    | `kubectl logs -n logging ds/filebeat -f` (JSON-записи с k8s-метаданными) |
| Логи пода напрямую | `kubectl logs -n hello-app deploy/hello-app`                            |
| Метрики приложения | `kubectl -n monitoring get --raw '/api/v1/namespaces/monitoring/services/kube-prometheus-stack-prometheus:9090/proxy/api/v1/query?query=app_http_requests_total'` (в поде Prometheus нет curl/sh — exec не сработает, используйте API-proxy) |
| Дашборд hello-app  | Grafana → Dashboards → «hello-app» (провижинится sidecar'ом из ConfigMap с лейблом `grafana_dashboard: "1"`) |
| Статус GitOps      | `flux get kustomizations` и `flux get sources git` (внутри WSL)         |

## Известные особенности WSL2

1. **`mount --make-rshared /` обязателен** — иначе node-exporter падает с
   `path "/" is not a shared or slave mount`. Фикс применяется в рантайме
   на каждом прогоне `deploy.sh` (шаг 1).
   **НЕ прописывайте его в `/etc/wsl.conf` `[boot] command`** — это роняет
   WSL VM (перезапуск каждые ~3 минуты, проверено).
2. **Подсеть WSL меняется после перезапуска** — `deploy.sh` пересчитывает пул
   MetalLB из текущего IP ноды при каждом прогоне.
3. **MetalLB L2-анонсы не доходят до Windows** в NAT-режиме WSL2 — external-IP
   балансировщика доступен изнутри WSL, а с Windows приложение доступно через
   `http://<node-ip>:<nodePort>`. Для стабильного `localhost` на Windows:
   `netsh interface portproxy add v4tov4 listenport=80 listenaddress=127.0.0.1 connectport=<nodePort> connectaddress=<node-ip>` (PowerShell от админа).
4. **Swap** выключается в `.wslconfig` на Windows (`swap=0`), иначе kubeadm не стартует.
5. **WSL VM засыпает при простое** — если в WSL нет активных процессов, VM выключается;
   при первом обращении поды кратковременно показывают `Unknown`, кластер поднимается
   сам за ~1 минуту (systemd стартует сервисы заново). `deploy.sh` и Flux это переживают.

## Версии компонентов

| Компонент            | Версия    |
|----------------------|-----------|
| Kubernetes (kubeadm) | v1.37.1   |
| flannel              | latest    |
| MetalLB              | v0.16.1   |
| Envoy Gateway        | v1.9.2    |
| kube-prometheus-stack| chart 91.8.2 (app v0.94.1) |
| Filebeat             | 9.2.0    |
| Helm                 | v3.22.0 |
| Flux CD              | v2.7.2  |
