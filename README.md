# k8s-homelab — Kubernetes-кластер в WSL с полной автоматизацией

Решение разворачивает в WSL2 (Ubuntu-24.04) kubeadm-кластер с приложением,
Gateway API (Envoy), балансировщиком (MetalLB), мониторингом (kube-prometheus-stack)
и сбором логов (Filebeat).

## Структура

```
├── bootstrap/                     # ОДИН РАЗ на свежей WSL (внутри WSL)
│   ├── 01-wsl-prereqs.sh          # systemd, swap off, mount --make-rshared /
│   ├── 02-install-kubeadm.sh      # containerd, kubeadm/kubelet/kubectl v1.37.1
│   ├── 03-cluster-init.sh         # kubeadm init + flannel CNI
│   └── 04-install-helm.sh         # helm v3.22.0
├── manifests/
│   ├── metallb-install/           # вендоренные манифесты MetalLB v0.16.1
│   └── flannel/                   # вендоренный манифест flannel
├── kustomize/
│   ├── base/                      # общие манифесты: hello-app, filebeat, MetalLB-пул
│   └── overlays/wsl/              # слой среды WSL (патч пула под текущую подсеть)
├── helm/
│   ├── values-monitoring.yaml     # values kube-prometheus-stack (дефолты)
│   └── values-gateway.yaml        # values envoy-gateway (дефолты)
├── deploy.sh                      # ГЛАВНАЯ КНОПКА: развёртывание всего стека
├── verify.sh                      # проверка здоровья всех компонентов
├── app/ + Dockerfile              # исходники приложения (Python/gunicorn)
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

## Что где смотреть

| Что                | Как                                                                     |
|--------------------|-------------------------------------------------------------------------|
| Приложение         | hosts: `172.26.20.204 hello-app` → `http://hello-app:<nodePort hello-gateway>`; порт — `kubectl -n envoy-gateway-system get svc` |
| Grafana (HTTPS)    | hosts: `172.26.20.204 grafana.hello-app` → `https://grafana.hello-app:<nodePort grafana-gateway>` (443:3xxxx). CA из секрета `root-ca-secret` (ns cert-manager) — импортировать в доверенные Windows для зелёного замка |
| Grafana (port-forward) | `kubectl port-forward svc/kube-prometheus-stack-grafana 3000:80 -n monitoring` → http://localhost:3000 (admin / пароль из секрета kube-prometheus-stack-grafana) |
| Prometheus UI      | `kubectl port-forward svc/kube-prometheus-stack-prometheus 9090:9090 -n monitoring` → http://localhost:9090 |
| Логи приложения    | `kubectl logs -n logging ds/filebeat -f` (JSON-записи с k8s-метаданными) |
| Логи пода напрямую | `kubectl logs -n hello-app deploy/hello-app`                            |

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

## Версии компонентов

| Компонент            | Версия    |
|----------------------|-----------|
| Kubernetes (kubeadm) | v1.37.1   |
| flannel              | latest    |
| MetalLB              | v0.16.1   |
| Envoy Gateway        | v1.9.2    |
| kube-prometheus-stack| chart 91.8.2 (app v0.94.1) |
| Filebeat             | 9.2.0     |
| Helm                 | v3.22.0   |
