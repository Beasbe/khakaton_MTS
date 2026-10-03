#!/usr/bin/env bash
# =============================================================================
#  Сборка и публикация образов приложения в локальный registry (k3s).
#  Использование:
#    ./scripts/build-images.sh                     # registry по умолчанию localhost:5000/full-proj
#    REGISTRY=localhost:5000/full-proj API_URL=http://localhost:30080 ./scripts/build-images.sh
# =============================================================================
set -euo pipefail

REGISTRY="${REGISTRY:-localhost:5000/full-proj}"
# URL бэкенда, вшиваемый во фронтенд при сборке. Пустая строка = относительные
# URL (/api, /storage) — работают и по HTTP :30080, и по HTTPS :30443.
# SSR-запросы внутри кластера ходят через BACKEND_INTERNAL_API_URL (helm).
API_URL="${API_URL:-}"

echo "==> Registry: ${REGISTRY}"
echo "==> API URL для фронтенда: ${API_URL}"

echo "==> Сборка backend (Laravel + nginx + exporter)..."
docker build -t "${REGISTRY}/backend:latest" ./CMS

echo "==> Сборка frontend (Next.js)..."
docker build \
  --build-arg NEXT_PUBLIC_API_URL="${API_URL}" \
  -t "${REGISTRY}/frontend:latest" ./It_project

echo "==> Подготовка WAF (ModSecurity + OWASP CRS)..."
docker pull -q owasp/modsecurity-crs:nginx-alpine
docker tag owasp/modsecurity-crs:nginx-alpine "${REGISTRY}/waf:latest"

echo "==> Публикация в registry..."
for img in backend frontend waf; do
  docker push -q "${REGISTRY}/${img}:latest"
done

echo "==> Готово. Образы в registry:"
curl -sf http://localhost:5000/v2/_catalog || true
