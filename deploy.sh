#!/bin/bash
# Шаг 5. Полное развёртывание стека на работающем kubeadm-кластере.
# Запуск:  bash deploy.sh
# Скрипт идемпотентен: повторный прогон не ломает ничего.
#
# Ожидания терпеливые: образы с quay.io из РФ качаются медленно - вместо
# падения по таймауту скрипт ждёт до 30 мин на компонент (с прогрессом),
# таймаут = предупреждение, а не FAIL. kustomize-apply ретраится сам
# (webhook-валидация переживает медленные образы).
#
# ВАЖНО про порядок: kustomize-apply идёт ПОСЛЕ kube-prometheus-stack,
# потому что ServiceMonitor требует CRD monitoring.coreos.com (из chartа),
# а ресурсы TLS-ингресса Grafana - namespace monitoring (создаёт helm).
# На свежей машине apply ДО мониторинга падает (поймано на VM).
#
# После перезапуска WSL прогон обновит пул MetalLB под новую подсеть.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"

# ══ Хелперы ожидания (не убивают скрипт) ════════════════════════════
# Каждая проверка блокирует до 30с; цикл - до ~30 мин с прогрессом;
# при исчерпании дедлайна - [WARN] и return 1 (вызывается через || true)
wait_available() {  # wait_available <ns> <deployment> <подпись>
  local ns="$1" name="$2" label="$3" n=0
  until kubectl -n "$ns" wait --for=condition=available "deployment/$name" --timeout=30s >/dev/null 2>&1; do
    n=$((n+1))
    if [ $((n % 6)) -eq 0 ]; then
      echo "    ... $label ждём ~$((n/2)) мин (образы могут качаться с quay.io)"
    fi
    if [ "$n" -ge 60 ]; then
      echo "    [WARN] $label не готов за ~30 мин — продолжаю (verify.sh покажет состояние)"
      return 1
    fi
    sleep 5
  done
  echo "    [OK] $label"
}
wait_rollout() {  # wait_rollout <ns> <target> <подпись>
  local ns="$1" target="$2" label="$3" n=0
  until kubectl -n "$ns" rollout status "$target" --timeout=30s >/dev/null 2>&1; do
    n=$((n+1))
    if [ $((n % 6)) -eq 0 ]; then
      echo "    ... $label ждём ~$((n/2)) мин"
    fi
    if [ "$n" -ge 60 ]; then
      echo "    [WARN] $label не готов за ~30 мин — продолжаю"
      return 1
    fi
    sleep 5
  done
  echo "    [OK] $label"
}

# ══ 0. Предусловия ══════════════════════════════════════════════════
command -v kubectl >/dev/null || { echo "FAIL: kubectl не найден (сначала bootstrap/02)"; exit 1; }
command -v helm    >/dev/null || { echo "FAIL: helm не найден (сначала bootstrap/04)"; exit 1; }
# WSL среда нестабильна: kubelet может кратковременно рестартовать вместе со
# статик-подами (API-сервер мигает). Ждём с ретраями до 6 минут.
n=0
until kubectl get nodes >/dev/null 2>&1; do
  n=$((n+1))
  if [ "$n" -ge 36 ]; then
    echo "FAIL: кластер недоступен за 6 минут (сначала bootstrap/03)"; exit 1
  fi
  sleep 10
done
echo "[0/7] Кластер доступен"

# ══ 1. WSL-фиксы ════════════════════════════════════════════════════
# Корень должен быть shared-mount, иначе node-exporter не стартует.
# (на обычной Ubuntu/VM корень уже shared - команда безвредна)
sudo mount --make-rshared /
echo "[1/7] mount --make-rshared / применён"

# ══ 2. MetalLB: установка (если ещё нет) ════════════════════════════
if ! kubectl get ns metallb-system >/dev/null 2>&1; then
  kubectl apply -f "$ROOT/manifests/metallb-install/metallb-native.yaml"
fi
wait_available metallb-system controller "MetalLB controller" || true
wait_rollout   metallb-system ds/speaker  "MetalLB speaker"    || true
echo "[2/7] MetalLB"

# ══ 3. Envoy Gateway: установка через helm (если ещё нет) ═══════════
# Ставится ДО kustomize-apply: он создаёт CRD Gateway, нужные для gateway.yaml
if ! kubectl get ns envoy-gateway-system >/dev/null 2>&1; then
  helm upgrade --install eg oci://docker.io/envoyproxy/gateway-helm \
    --version v1.9.2 \
    --values "$ROOT/helm/values-gateway.yaml" \
    -n envoy-gateway-system --create-namespace
fi
wait_available envoy-gateway-system envoy-gateway "Envoy Gateway" || true
echo "[3/7] Envoy Gateway"

# ══ 4. cert-manager: установка через helm (если ещё нет) ════════════
# Нужен ДО kustomize-apply: создаёт CRD Certificate/ClusterIssuer,
# на которые ссылаются манифесты TLS-ингресса Grafana.
if ! kubectl get ns cert-manager >/dev/null 2>&1; then
  helm repo add --force-update jetstack https://charts.jetstack.io
  helm repo update >/dev/null
  helm upgrade --install cert-manager jetstack/cert-manager \
    --version v1.21.2 \
    --set crds.enabled=true \
    -n cert-manager --create-namespace
fi
wait_available cert-manager cert-manager         "cert-manager"         || true
wait_available cert-manager cert-manager-webhook "cert-manager webhook" || true
echo "[4/7] cert-manager"

# ══ 5. Пул MetalLB: вычислить из текущей подсети WSL ════════════════
# Подсеть WSL меняется после каждого перезапуска, поэтому диапазон
# пересчитывается на каждом прогоне. Берём последние 64 адреса /20:
# не задеваем broadcast, node IP и Windows-хост (в другом конце подсети).
NODE_CIDR=$(ip -4 -o addr show eth0 | awk '{print $4}')
RANGE=$(python3 -c "
import ipaddress
net = ipaddress.ip_interface('${NODE_CIDR}').network
hosts = list(net.hosts())
print(f'{hosts[-64]}-{hosts[-1]}')")
cat > "$ROOT/kustomize/overlays/wsl/patches/lb-pool.yaml" <<EOF
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: wsl-pool
spec:
  addresses:
    - ${RANGE}
EOF
echo "[5/7] Пул MetalLB: ${RANGE} (подсеть ноды ${NODE_CIDR})"

# ══ 6. Мониторинг: kube-prometheus-stack через helm (если ещё нет) ══
# Ставится ДО kustomize-apply: создаёт ns monitoring и CRD ServiceMonitor
if ! kubectl get ns monitoring >/dev/null 2>&1; then
  helm repo add --force-update prometheus-community https://prometheus-community.github.io/helm-charts
  helm repo update >/dev/null
  helm upgrade --install kube-prometheus-stack prometheus-community/kube-prometheus-stack \
    --version 91.8.2 \
    --values "$ROOT/helm/values-monitoring.yaml" \
    -n monitoring --create-namespace
fi
wait_available monitoring kube-prometheus-stack-operator "Prometheus operator" || true
echo "[6/7] kube-prometheus-stack"

# ══ 7. Свои манифесты одним kustomize (+ авто-ретраи) ═══════════════
# hello-app (deployment+svc+Gateway+HTTPRoute+ServiceMonitor+дашборд),
# filebeat, пул MetalLB, TLS-ингресс Grafana (CA + сертификат + Gateway + HTTPRoute).
# Certificate/IPAddressPool валидируются webhook'ами - если контроллер ещё
# тянет образ, apply падает; ретраи это переживают
ok=0
for i in 1 2 3 4 5; do
  if kubectl apply -k "$ROOT/kustomize/overlays/wsl" >/tmp/kustomize-apply.log 2>&1; then
    ok=1
    break
  fi
  echo "    apply не прошёл (попытка $i/5), последние ошибки:"
  tail -4 /tmp/kustomize-apply.log
  echo "    повтор через 30с..."
  sleep 30
done
if [ "$ok" != 1 ]; then
  echo "FAIL: kustomize-apply не прошёл за 5 попыток, последние ошибки:"
  tail -15 /tmp/kustomize-apply.log
  exit 1
fi
echo "[7/7] Манифесты применены (kubectl apply -k overlays/wsl)"

# ══ Проверка здоровья (незавоалидный хвост: результат в выводе) ═════
echo
bash "$ROOT/verify.sh" || true
