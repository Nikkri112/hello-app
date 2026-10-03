#!/bin/bash
# Шаг 4. Установка Helm (пакетный менеджер Kubernetes).
# Запускается ОДИН раз:  bash bootstrap/04-install-helm.sh
set -euo pipefail

HELM_VERSION="v3.22.0"

if command -v helm >/dev/null; then
  echo "helm already installed: $(helm version --short)"
  exit 0
fi

curl -fsSL "https://get.helm.sh/helm-${HELM_VERSION}-linux-amd64.tar.gz" -o /tmp/helm.tgz
sudo tar -C /usr/local/bin -xzf /tmp/helm.tgz --strip-components=1 linux-amd64/helm
rm -f /tmp/helm.tgz
echo "helm installed: $(helm version --short)"
