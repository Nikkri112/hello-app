#!/bin/bash
# Шаг 3. Инициализация кластера kubeadm + CNI flannel.
# Запуск:  bash bootstrap/03-cluster-init.sh
# Скрипт идемпотентен: если кластер уже есть - только докатывает flannel и taint.
# Предусловие: шаги 01 и 02 выполнены, WSL перезапущена.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# kubeadm приводит имя ноды к нижнему регистру (DNS-1123), hostname может вернуть верхний
NODE_NAME=$(hostname | tr A-Z a-z)

if kubectl get nodes >/dev/null 2>&1; then
  echo "Cluster already exists - skipping init"
else
  # ── подстраховка: рантайм и kubelet должны работать перед init
  sudo systemctl enable --now containerd
  sudo systemctl enable --now kubelet
  sleep 3

  # ── init: pod CIDR 10.244.0.0/16 - это дефолт flannel
  sudo kubeadm init --pod-network-cidr=10.244.0.0/16

  # ── kubeconfig для пользователя
  mkdir -p "$HOME/.kube"
  sudo cp /etc/kubernetes/admin.conf "$HOME/.kube/config"
  sudo chown "$(id -u):$(id -g)" "$HOME/.kube/config"
fi

export KUBECONFIG="$HOME/.kube/config"

# ── ждём регистрации ноды (kubelet регистрирует её не сразу после init)
echo "Waiting for node registration (${NODE_NAME})..."
for i in $(seq 1 60); do
  kubectl get node "$NODE_NAME" >/dev/null 2>&1 && break
  sleep 5
done
kubectl get node "$NODE_NAME" || { echo "FAIL: нода не зарегистрировалась"; exit 1; }

# ── CNI flannel (вендоренный манифест из репозитория flannel-io)
# Применяем ВСЕГДА: нода станет Ready только с CNI. Apply идемпотентен.
kubectl apply -f "$ROOT/manifests/flannel/kube-flannel.yml"

# ── ждём готовности control-plane (Ready появится после запуска CNI)
kubectl wait --for=condition=Ready node/"$NODE_NAME" --timeout=300s

# ── одна нода = control-plane: снимаем taint, чтобы поды запускались на ней
kubectl taint nodes --all node-role.kubernetes.io/control-plane- 2>/dev/null || true

echo "=== DONE: кластер инициализирован ==="
kubectl get nodes -o wide
