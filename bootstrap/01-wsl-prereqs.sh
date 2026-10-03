#!/bin/bash
# Шаг 1. Предварительные требования WSL: systemd, swap, shared-маунт корня.
# Запускается ОДИН раз на свежей WSL:  bash bootstrap/01-wsl-prereqs.sh
# После запуска требуется перезапуск WSL (wsl --shutdown из PowerShell).
set -euo pipefail

# ── systemd в /etc/wsl.conf (без него kubelet/containerd не работают как сервисы)
if ! grep -q "^\[boot\]" /etc/wsl.conf 2>/dev/null; then
  echo "[boot]"                    | sudo tee -a /etc/wsl.conf >/dev/null
  echo "systemd=true"              | sudo tee -a /etc/wsl.conf >/dev/null
  echo "Added [boot] systemd=true to /etc/wsl.conf"
else
  echo "[boot] already present in /etc/wsl.conf"
fi

# ── swap выключить (kubeadm отказывается работать со swap)
if [ "$(swapon --show | wc -l)" -gt 0 ]; then
  sudo swapoff -a
  # убрать swap из /etc/fstab, чтобы не поднялся после перезагрузки
  sudo sed -i.bak '/\sswap\s/s/^/#/' /etc/fstab
  echo "Swap disabled"
else
  echo "Swap already off"
fi
# Внимание: swap в WSL управляется файлом .wslconfig на Windows-стороне:
#   [wsl2]
#   swap=0

# ── модули ядра и sysctl для Kubernetes
sudo modprobe overlay
sudo modprobe br_netfilter
cat <<EOF | sudo tee /etc/modules-load.d/k8s.conf
overlay
br_netfilter
EOF
cat <<EOF | sudo tee /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF
sudo sysctl --system >/dev/null
echo "Kernel modules and sysctl configured"

# ── КРИТИЧНО ДЛЯ WSL: корень должен быть shared-mount.
# Иначе node-exporter (hostPath /) падает:
#   'path "/" is mounted on "/" but it is not a shared or slave mount'
# ВАЖНО: mount --make-rshared / НЕЛЬЗЯ прописывать в /etc/wsl.conf [boot] command -
# это роняет WSL VM (перезапуск каждые ~3 минуты). Фикс применяется в рантайме
# на каждом прогоне deploy.sh (шаг 1).
sudo mount --make-rshared /
echo "Root mount is now shared"

echo "=== DONE. Теперь перезапусти WSL: wsl --shutdown (PowerShell) ==="
