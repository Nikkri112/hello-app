#!/bin/bash
# Шаг 2. Установка containerd, kubeadm, kubelet, kubectl (Kubernetes v1.37).
# Запускается ОДИН раз на свежей WSL:  bash bootstrap/02-install-kubeadm.sh
set -euo pipefail

K8S_REPO="https://pkgs.k8s.io/core:/stable:/v1.37/deb"
K8S_VERSION="1.37.1"

sudo apt-get update -qq
sudo apt-get install -y -qq apt-transport-https ca-certificates curl gpg

# ── репозиторий Kubernetes (v1.37) с ключом
sudo install -m 0755 -d /etc/apt/keyrings
if [ ! -f /etc/apt/keyrings/kubernetes-apt-keyring.gpg ]; then
  curl -fsSL "${K8S_REPO}/Release.key" | sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
fi
echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] ${K8S_REPO} /" | \
  sudo tee /etc/apt/sources.list.d/kubernetes.list >/dev/null

# ── containerd (CRI-рантайм)
if ! command -v containerd >/dev/null; then
  sudo apt-get install -y -qq containerd
fi
# конфиг по умолчанию + драйвер cgroup = systemd (требование kubeadm)
if [ ! -f /etc/containerd/config.toml ] || ! grep -q "SystemdCgroup = true" /etc/containerd/config.toml; then
  sudo mkdir -p /etc/containerd
  containerd config default | sudo tee /etc/containerd/config.toml >/dev/null
  sudo sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
  sudo systemctl restart containerd
fi
sudo systemctl enable --now containerd
echo "containerd: $(containerd --version | awk '{print $3}')"

# ── kubeadm, kubelet, kubectl (пиннены, чтобы apt не обновил сам)
sudo apt-get update -qq
sudo apt-get install -y -qq kubelet="${K8S_VERSION}-*" kubeadm="${K8S_VERSION}-*" kubectl="${K8S_VERSION}-*"
sudo apt-mark hold kubelet kubeadm kubectl
echo "kubeadm: $(kubeadm version -o short)"
echo "kubelet: $(kubelet --version | awk '{print $2}')"

# kubelet должен работать как systemd-сервис
sudo systemctl enable --now kubelet
echo "=== DONE: компоненты Kubernetes установлены ==="
