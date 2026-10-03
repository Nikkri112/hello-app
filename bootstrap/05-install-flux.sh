#!/bin/bash
# Шаг 6b. Flux CD (GitOps): установка контроллеров + привязка к git-репо.
# Запуск:  bash bootstrap/05-install-flux.sh <owner>/<repo> [branch]
# Пример:  bash bootstrap/05-install-flux.sh Nikkri112/hello-app main
# Репозиторий публичный - Flux тянет его без токена.
# Скрипт идемпотентен: повторный прогон не ломает ничего.
set -euo pipefail

REPO="${1:?Использование: $0 <owner>/<repo> [branch]}"
BRANCH="${2:-main}"

# ══ Предусловия ═════════════════════════════════════════════════════
command -v kubectl >/dev/null || { echo "FAIL: kubectl не найден (сначала bootstrap/02)"; exit 1; }
# WSL среда нестабильна: ждём API-сервер с ретраями до 2 минут
for i in $(seq 1 24); do
  kubectl get nodes >/dev/null 2>&1 && break
  sleep 5
done
kubectl get nodes >/dev/null 2>&1 || { echo "FAIL: кластер недоступен (сначала bootstrap/03)"; exit 1; }
echo "[0/4] Кластер доступен"

# ══ 1. flux CLI (если ещё нет) ══════════════════════════════════════
# Версия фиксированная: api.github.com (lookup "latest") из WSL часто недоступен,
# а прямые загрузки с github.com/releases работают.
FLUX_VERSION="${FLUX_VERSION:-2.7.2}"
if ! command -v flux >/dev/null 2>&1; then
  curl -s --connect-timeout 15 https://fluxcd.io/install.sh | sudo FLUX_VERSION="${FLUX_VERSION}" bash
fi
echo "[1/4] flux: $(flux --version)"

# ══ 2. Контроллеры Flux в кластер (идемпотентно) ════════════════════
if ! kubectl get ns flux-system >/dev/null 2>&1; then
  flux install
  echo "[2/4] Контроллеры Flux установлены"
else
  echo "[2/4] flux-system уже установлен"
fi

# ══ 3. Источник: git-репо (публичный - тянется без токена) ══════════
if ! kubectl -n flux-system get gitrepository homelab >/dev/null 2>&1; then
  flux create source git homelab \
    --url "https://github.com/${REPO}.git" \
    --branch "${BRANCH}" \
    --interval 30s
  echo "[3/4] GitRepository homelab создан"
else
  echo "[3/4] GitRepository homelab уже существует"
fi

# ══ 4. Kustomization: применяет overlay, следит за здоровьем ════════
if ! kubectl -n flux-system get kustomization homelab >/dev/null 2>&1; then
  flux create kustomization homelab \
    --source=GitRepository/homelab \
    --path "./kustomize/overlays/wsl" \
    --prune true \
    --interval 1m \
    --health-check "Deployment/hello-app.hello-app" \
    --health-check-timeout 3m
  echo "[4/4] Kustomization homelab создана"
else
  echo "[4/4] Kustomization homelab уже существует"
fi

echo
echo "══ Статус ══"
kubectl -n flux-system get gitrepository homelab
kubectl -n flux-system get kustomization homelab
