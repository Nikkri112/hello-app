#!/bin/bash
# Шаг 5. Полное развёртывание стека на работающем kubeadm-кластере.
# Запуск:  bash deploy.sh
# Скрипт идемпотентен: повторный прогон не ломает ничего.
# После перезапуска WSL прогон обновит пул MetalLB под новую подсеть.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"

# ══ 0. Предусловия ══════════════════════════════════════════════════
command -v kubectl >/dev/null || { echo "FAIL: kubectl не найден (сначала bootstrap/02)"; exit 1; }
command -v helm    >/dev/null || { echo "FAIL: helm не найден (сначала bootstrap/04)"; exit 1; }
# WSL среда нестабильна: kubelet может кратковременно рестартовать вместе со
# статик-подами (API-сервер мигает). Ждём с ретраями до 2 минут вместо мгновенного падения.
for i in $(seq 1 24); do
  kubectl get nodes >/dev/null 2>&1 && break
  sleep 5
done
kubectl get nodes >/dev/null 2>&1 || { echo "FAIL: кластер недоступен (сначала bootstrap/03)"; exit 1; }
echo "[0/7] Кластер доступен"

# ══ 1. WSL-фиксы ════════════════════════════════════════════════════
# Корень должен быть shared-mount, иначе node-exporter не стартует:
#   'path "/" is mounted on "/" but it is not a shared or slave mount'
sudo mount --make-rshared /
echo "[1/7] mount --make-rshared / применён"

# ══ 2. MetalLB: установка (если ещё нет) ════════════════════════════
if ! kubectl get ns metallb-system >/dev/null 2>&1; then
  kubectl apply -f "$ROOT/manifests/metallb-install/metallb-native.yaml"
  kubectl -n metallb-system wait --for=condition=available deployment/controller --timeout=180s
  kubectl -n metallb-system rollout status ds/speaker --timeout=180s
  echo "[2/7] MetalLB установлен"
else
  echo "[2/7] MetalLB уже установлен"
fi

# ══ 3. Envoy Gateway: установка через helm (если ещё нет) ═══════════
# Ставится ДО kustomize-apply: он создаёт CRD Gateway, нужные для gateway.yaml
if ! kubectl get ns envoy-gateway-system >/dev/null 2>&1; then
  helm upgrade --install eg oci://docker.io/envoyproxy/gateway-helm \
    --version v1.9.2 \
    --values "$ROOT/helm/values-gateway.yaml" \
    -n envoy-gateway-system --create-namespace
  kubectl -n envoy-gateway-system wait --for=condition=available deployment/envoy-gateway --timeout=300s
  echo "[3/7] Envoy Gateway установлен"
else
  echo "[3/7] Envoy Gateway уже установлен"
fi

# ══ 4. cert-manager: установка через helm (если ещё нет) ════════════
# Нужен ДО kustomize-apply: создаёт CRD Certificate/ClusterIssuer,
# на которые ссылаются манифесты TLS-ингресса Grafana.
if ! kubectl get ns cert-manager >/dev/null 2>&1; then
  helm repo add jetstack https://charts.jetstack.io 2>/dev/null || true
  helm repo update >/dev/null
  helm upgrade --install cert-manager jetstack/cert-manager \
    --version v1.21.2 \
    --set crds.enabled=true \
    -n cert-manager --create-namespace
  kubectl -n cert-manager wait --for=condition=available deployment/cert-manager --timeout=300s
  kubectl -n cert-manager wait --for=condition=available deployment/cert-manager-webhook --timeout=300s
  echo "[4/7] cert-manager установлен"
else
  echo "[4/7] cert-manager уже установлен"
fi

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

# ══ 6. Свои манифесты одним kustomize ═══════════════════════════════
# hello-app (deployment+svc+Gateway+HTTPRoute), filebeat, пул MetalLB,
# TLS-ингресс Grafana (CA + сертификат + Gateway + HTTPRoute)
kubectl apply -k "$ROOT/kustomize/overlays/wsl"
echo "[6/7] Манифесты применены (kubectl apply -k overlays/wsl)"

# ══ 7. Мониторинг: kube-prometheus-stack через helm (если ещё нет) ══
if ! kubectl get ns monitoring >/dev/null 2>&1; then
  helm repo add prometheus-community https://prometheus-community.github.io/helm-charts 2>/dev/null || true
  helm repo update >/dev/null
  helm upgrade --install kube-prometheus-stack prometheus-community/kube-prometheus-stack \
    --version 91.8.2 \
    --values "$ROOT/helm/values-monitoring.yaml" \
    -n monitoring --create-namespace
  kubectl -n monitoring wait --for=condition=available deployment/kube-prometheus-stack-operator --timeout=300s
  echo "[7/7] kube-prometheus-stack установлен"
else
  echo "[7/7] kube-prometheus-stack уже установлен"
fi

# ══ Проверка здоровья ═══════════════════════════════════════════════
echo
bash "$ROOT/verify.sh"
