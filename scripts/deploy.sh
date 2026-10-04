#!/usr/bin/env bash
# =============================================================================
#  Развёртывание решения в k3s (Ubuntu 24.04). Одна команда:
#    ./scripts/deploy.sh
#
#  Состав:
#    * Gateway API: CRD (standard channel) + GatewayClass (Traefik v3);
#    * Traefik v3 (реализация Gateway API, NodePort 30080);
#    * приложение: helm-чарт ./helm (backend+nginx+exporter, mysql, frontend,
#      WAF ModSecurity, Gateway + HTTPRoute);
#    * мониторинг: Prometheus + node-exporter;
#    * логирование: Fluent Bit (DaemonSet) -> Loki.
#
#  Требования: kubectl, helm, работающий кластер k3s, образы в registry
#  (см. scripts/build-images.sh). Секреты — в файле local-secrets.yaml
#  (не коммитится; шаблон — local-secrets.example.yaml).
# =============================================================================
set -euo pipefail

REGISTRY="${REGISTRY:-localhost:5000/full-proj}"
NAMESPACE="full-proj"
GATEWAY_API_VERSION="${GATEWAY_API_VERSION:-v1.5.1}"
SECRETS_FILE="${SECRETS_FILE:-local-secrets.yaml}"

echo "==> Проверка зависимостей..."
command -v kubectl >/dev/null || { echo "kubectl не найден"; exit 1; }
command -v helm >/dev/null || { echo "helm не найден"; exit 1; }
kubectl cluster-info >/dev/null || { echo "Кластер недоступен (kubectl cluster-info)"; exit 1; }

# Namespace приложения нужен уже на шаге 3 (gen-cert.sh и Secret) —
# создаём заранее, идемпотентно.
kubectl create namespace "${NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f - >/dev/null

# Секреты приложения: приоритет — SOPS-шифрованный helm/secrets/dev.yaml
# (в git), fallback — local-secrets.yaml (gitignored, для быстрого локального
# стенда). sops читает приватный age-ключ из ~/.config/sops/age/keys.txt
# или из env SOPS_AGE_KEY.
SECRETS_VALUES=""
if [ -f helm/secrets/dev.yaml ] && command -v sops >/dev/null 2>&1; then
  SECRETS_VALUES="$(mktemp)"
  sops -d helm/secrets/dev.yaml > "${SECRETS_VALUES}"
  echo "==> Секреты: SOPS-расшифровка helm/secrets/dev.yaml"
elif [ -f "${SECRETS_FILE}" ]; then
  SECRETS_VALUES="${SECRETS_FILE}"
  echo "==> Секреты: local-secrets.yaml (без SOPS)"
else
  echo "Ошибка: нужен helm/secrets/dev.yaml (с sops) ИЛИ ${SECRETS_FILE}" >&2
  exit 1
fi

# APP_KEY должен быть реальным ключом, а не плейсхолдером из шаблона
if grep -q 'base64:CHANGE_ME' "${SECRETS_VALUES}" 2>/dev/null; then
  echo "Ошибка: secrets.APP_KEY — плейсхолдер CHANGE_ME. Сгенерируйте ключ:" >&2
  echo "  echo \"base64:\$(openssl rand -base64 32)\"" >&2
  exit 1
fi

# Workaround для k3s v1.36.x: CoreDNS может стартовать без env
# KUBERNETES_SERVICE_HOST/PORT — DNS кластера тогда не работает (NXDOMAIN).
# Patch применяется только если env отсутствует; безвреден для других версий k3s.
if ! kubectl get deployment coredns -n kube-system -o jsonpath='{.spec.template.spec.containers[0].env}' 2>/dev/null | grep -q KUBERNETES_SERVICE_HOST; then
  K8S_SVC_IP=$(kubectl get svc kubernetes -o jsonpath='{.spec.clusterIP}')
  kubectl patch deployment coredns -n kube-system --type=merge -p "{\"spec\":{\"template\":{\"spec\":{\"containers\":[{\"name\":\"coredns\",\"env\":[{\"name\":\"KUBERNETES_SERVICE_HOST\",\"value\":\"${K8S_SVC_IP}\"},{\"name\":\"KUBERNETES_SERVICE_PORT\",\"value\":\"443\"}]}]}}}}" >/dev/null 2>&1 || true
  kubectl rollout restart deployment coredns -n kube-system >/dev/null 2>&1 || true
  echo "==> CoreDNS: применён workaround k3s v1.36.x (env KUBERNETES_SERVICE_HOST/PORT)"
fi

echo "==> Helm-чарты тянутся напрямую из OCI-регистри (ghcr.io) — без helm repo..."

CHART_PROMETHEUS="${CHART_PROMETHEUS:-oci://ghcr.io/prometheus-community/charts/prometheus}"
CHART_TRAEFIK="${CHART_TRAEFIK:-oci://ghcr.io/traefik/helm/traefik}"
CHART_LOKI="${CHART_LOKI:-oci://ghcr.io/grafana/helm-charts/loki}"
CHART_FLUENT_BIT="${CHART_FLUENT_BIT:-oci://ghcr.io/fluent/helm-charts/fluent-bit}"
CHART_GRAFANA="${CHART_GRAFANA:-oci://ghcr.io/grafana/helm-charts/grafana}"
CHART_ARGOCD="${CHART_ARGOCD:-oci://ghcr.io/argoproj/argo-helm/argo-cd}"

echo "==> 1/7 Gateway API: CRD v${GATEWAY_API_VERSION} (GatewayClass создаст Traefik-чарт)..."
kubectl apply -f "https://github.com/kubernetes-sigs/gateway-api/releases/download/${GATEWAY_API_VERSION}/standard-install.yaml"

echo "==> 2/7 Traefik v3 (реализация Gateway API, NodePort 30080 HTTP + 30443 HTTPS)..."
helm upgrade --install traefik "${CHART_TRAEFIK}" \
  -n traefik --create-namespace \
  -f infra/traefik/values.yaml

echo "==> 3/7 TLS-сертификат + секреты приложения (само приложение разворачивает Argo CD)..."
./scripts/gen-cert.sh
echo
# GitOps: приложение full-proj управляется Argo CD из ветки main
# (argocd/application.yaml). Здесь готовим только то, что живёт ВНЕ git:
#  * Secret app-secrets — рендерится шаблоном чарта из local-secrets.yaml;
#  * TLS-секрет full-proj-tls — создан gen-cert.sh выше.
helm template full-proj ./helm -f "${SECRETS_VALUES}" -s templates/secrets.yaml | kubectl apply -f -
if [ "${SECRETS_VALUES}" != "${SECRETS_FILE}" ]; then rm -f "${SECRETS_VALUES}"; fi

echo "==> 4/7 Мониторинг: Prometheus (с node-exporter и kube-state-metrics из чарта)..."
helm upgrade --install prometheus "${CHART_PROMETHEUS}" \
  -n monitoring --create-namespace \
  -f infra/prometheus/values.yaml

echo "==> 5/7 Grafana (дашборды Prometheus + Loki, NodePort 30300)..."
: "${GRAFANA_ADMIN_PASSWORD:?GRAFANA_ADMIN_PASSWORD не задан — см. README (DevSecOps)}"
kubectl create namespace monitoring --dry-run=client -o yaml | kubectl apply -f - >/dev/null
kubectl create secret generic grafana-admin-secret -n monitoring \
  --from-literal=admin-user=admin \
  --from-literal=admin-password="${GRAFANA_ADMIN_PASSWORD}" \
  --dry-run=client -o yaml | kubectl apply -f - >/dev/null
kubectl create configmap grafana-dashboards -n monitoring \
  --from-file=infra/grafana/dashboards \
  --dry-run=client -o yaml | kubectl apply -f - >/dev/null
helm upgrade --install grafana "${CHART_GRAFANA}" \
  -n monitoring \
  -f infra/grafana/values.yaml

echo "==> 6/7 Логирование: Loki + Fluent Bit..."
helm upgrade --install loki "${CHART_LOKI}" \
  -n logging --create-namespace \
  -f infra/logging/loki-values.yaml
helm upgrade --install fluent-bit "${CHART_FLUENT_BIT}" \
  -n logging \
  -f infra/logging/fluentbit-values.yaml

echo "==> 7/7 GitOps: Argo CD + Application full-proj (из ветки main репозитория)..."
helm upgrade --install argocd "${CHART_ARGOCD}" \
  -n argocd --create-namespace \
  -f infra/argocd/values.yaml
kubectl apply -f argocd/application.yaml
kubectl rollout status deployment argocd-server -n argocd --timeout=300s || true
echo "==> Ожидание первого sync'а Argo CD (rollout приложения)..."
for d in backend frontend waf mysql; do
  kubectl rollout status deployment/${d} -n "${NAMESPACE}" --timeout=600s || true
done

echo ""
echo "============================================================"
echo " Развёртывание запущено. Проверка:"
echo ""
echo "  kubectl get pods -n ${NAMESPACE}"
echo "  kubectl get gateway,httproute -n ${NAMESPACE}"
echo ""
# приложение: GitOps (Argo CD) — сверка с репозиторием в http://<node-ip>:30444
curl -sk https://localhost:30443/api/news | head -c 300

echo "  # Grafana (метрики + логи): http://<node-ip>:30300 (admin / GRAFANA_ADMIN_PASSWORD)"
echo "  # Argo CD (GitOps): http://<node-ip>:30444 — пароль:"
echo "  #   kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d"
echo ""
echo "  # WAF: легитимный трафик 200, атаки 403"
echo "  curl -s -o /dev/null -w '%{http_code}\n' http://localhost:30080/"
echo "  curl -s -o /dev/null -w '%{http_code}\n' -A 'sqlmap/1.7.2' http://localhost:30080/"
echo "  curl -s -o /dev/null -w '%{http_code}\n' 'http://localhost:30080/?id=1%27%20OR%20%271%27%3D%271'"
echo ""
echo "  # метрики Prometheus:"
echo "  kubectl port-forward -n monitoring svc/prometheus-server 9090:80"
echo "  curl 'http://localhost:9090/api/v1/query?query=up' | jq '.data.result[] | {job: .metric.job, value: .value[1]}'"
echo ""
echo "  # логи Fluent Bit -> Loki (после обращения к приложению):"
echo "  kubectl port-forward -n logging svc/loki 3100:3100"
echo "  curl -G 'http://localhost:3100/loki/api/v1/query_range' --data-urlencode 'query={namespace=\"full-proj\"}'"
echo "============================================================"
