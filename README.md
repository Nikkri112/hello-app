# hello-app — разворачиваемое веб-приложение с продакшен-обвязкой

Полноценное k8s-приложение «из коробки»: сервис с Gateway API (Envoy),
балансировщиком (MetalLB), мониторингом (Prometheus/Grafana), сбором логов
(Filebeat) и полным CI/CD (GitHub Actions + Flux GitOps). Разворачивается
на любой свежей Ubuntu/WSL-машине одной кнопкой.

## Функционал приложения

| Эндпоинт | Что делает |
|----------|------------|
| `GET /` | JSON с приветствием и именем пода, который ответил |
| `GET /healthz` | health-check (используется liveness/readiness-пробами) |
| `GET /metrics` | метрики Prometheus: `app_http_requests_total`, гистограмма задержек |

Безопасность: запуск не от root (UID 1000), read-only корневая ФС (запись
только в `/tmp` и `/var/log/app`), seccomp RuntimeDefault, drop ALL capabilities,
NetworkPolicy на входящий трафик.

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
Envoy Gateway (Gateway API): HTTPRoute → приложение (HTTP)
Prometheus: собирает метрики приложения через ServiceMonitor
Grafana: дашборд «hello-app» провижинится sidecar'ом автоматически
Filebeat (daemonset): JSON-логи с k8s-метаданными
```

- Стек описан декларативно в kustomize (base + overlay среды); helm-чарты
  (Envoy Gateway, cert-manager, kube-prometheus-stack) ставит `deploy.sh`
  с фиксированными версиями.
- Flux применяет overlay и следит за здоровьем Deployment hello-app
  (health check в Kustomization).
- ServiceMonitor помечен лейблом `release: kube-prometheus-stack`
  (селектор Prometheus из helm-дефолтов).

## Структура

```
├── bootstrap/                     # ОДИН РАЗ на свежей машине
│   ├── 01-wsl-prereqs.sh          # только для WSL: systemd, swap off, rshared
│   ├── 02-install-kubeadm.sh      # containerd, kubeadm/kubelet/kubectl v1.37.1
│   ├── 03-cluster-init.sh         # kubeadm init + flannel CNI
│   ├── 04-install-helm.sh         # helm v3.22.0
│   └── 05-install-flux.sh         # Flux CD: контроллеры + привязка к git-репо
├── manifests/
│   ├── metallb-install/           # вендоренные манифесты MetalLB v0.16.1
│   └── flannel/                   # вендоренный манифест flannel
├── kustomize/
│   ├── base/                      # hello-app (+ServiceMonitor+дашборд), filebeat, MetalLB-пул, TLS-ингресс Grafana
│   └── overlays/wsl/              # слой среды (патч пула под текущую подсеть)
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

## Развёртывание

```bash
bash bootstrap/01-wsl-prereqs.sh     # только для WSL-машин
bash bootstrap/02-install-kubeadm.sh
bash bootstrap/03-cluster-init.sh    # кластер поднят
bash bootstrap/04-install-helm.sh
bash deploy.sh                       # весь стек: MetalLB, Gateway, приложение, мониторинг, логи
bash verify.sh                       # проверка здоровья: нода, поды, Gateway, приложение, метрики, логи
```

`deploy.sh` идемпотентен: повторный запуск докатит недостающее и обновит
пул MetalLB под текущую подсеть.

## CI/CD (GitHub Actions + Flux GitOps)

```
git push в main (app/ или Dockerfile)
  → CI: ruff + pytest → docker build → smoke-тест в контейнере
        → push образа в Docker Hub (тег <git-sha> + latest)
  → CD (запускается сам при успехе CI): подставляет тег в kustomize,
        коммит от github-actions[bot]
  → Flux: применяет в кластер за ~1,5 минуты, поды перекатываются
```

- тесты упали → образ не публикуется, CD не запускается, кластер не трогается;
- CD-коммит меняет только `kustomize/` → CI на него не реагирует (нет цикла);
- PR-ветки: только линт+тесты+сборка, без публикации и деплоя.

Секреты (Settings → Secrets and variables → Actions): `DOCKERHUB_USERNAME`,
`DOCKERHUB_TOKEN` (Personal access token с правами Read & Write).

Первичная привязка Flux к репо (один раз, в кластере):

```bash
bash bootstrap/05-install-flux.sh Nikkri112/hello-app main
```

Откат: revert CD-коммита (Flux вернёт предыдущий тег образа) либо
`kubectl rollout undo -n hello-app deploy/hello-app`.

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
