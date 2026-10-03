# SPEC-04 — Мониторинг (Prometheus)

> Источник требований: кейс «MTC ENGINEER HACK», раздел 4 «Мониторинг».

## 0. Мета

| | |
|---|---|
| Статус | ✅ **Реализовано и проверено** |
| Стек | Prometheus v3.15.0 (чарт prometheus-community/prometheus 29.35.0), node-exporter, kube-state-metrics, **Grafana v12.3.1** (дашборды) |

## 1. Требования (из кейса)

| ID | Требование | Статус |
|----|-----------|--------|
| FR-MON-1 | Prometheus развёрнут, собирает метрики минимум одного компонента | ✅ |
| FR-MON-2 | Target доступен Prometheus | ✅ (см. матрицу ниже) |
| FR-MON-3 | Продемонстрировано получение метрик Prometheus query | ✅ ниже |
| FR-MON-4 | README: какие метрики собираются и как проверить | ✅ ниже |

## 2. Реализация

- Prometheus развёрнут Helm-чартом в namespace `monitoring`
  (`infra/prometheus/values.yaml`, retentiion 3d, без PV — emptyDir);
- встроенные subcharts чарта: **node-exporter** (DaemonSet, hostNetwork) и
  **kube-state-metrics**; pushgateway/alertmanager отключены;
- дефолтные scrape-джобы чарта собирают: kubelet (`kubernetes-nodes`),
  **cadvisor** (`kubernetes-nodes-cadvisor`), apiserver, kube-state-metrics;
- **метрики приложения**: sidecar `nginx-prometheus-exporter:1.4.0` в поде
  `backend` (читает `stub_status` nginx), подхватывается джобой `kubernetes-pods`
  по аннотациям `prometheus.io/scrape: "true"`, порт 9113.

| Job | Компонент | Метрики |
|---|---|---|
| `node-exporter` | узел | CPU/RAM/диск/сеть |
| `kubernetes-nodes-cadvisor` | kubelet | метрики контейнеров (CPU/RAM) |
| `kubernetes-pods` | nginx приложения | `nginx_http_requests_total` (кол-во запросов), соединения |
| `kubernetes-service-endpoints` | kube-state-metrics | состояние подов/деплойментов |
| `kubernetes-nodes` / `kubernetes-api-servers` | k8s | состояние кластера |

### Визуализация: Grafana

Grafana (чарт `ghcr.io/grafana/helm-charts/grafana`, `infra/grafana/values.yaml`)
развёрнута в namespace `monitoring`, NodePort **30300** (`http://<node-ip>:30300`,
login `admin` / `GRAFANA_ADMIN_PASSWORD`, по умолчанию `admin`):

- источники данных провайзятся автоматически: **Prometheus**
  (`prometheus-server.monitoring.svc.cluster.local:80`) и **Loki**
  (`loki.logging.svc.cluster.local:3100`);
- дашборды (ConfigMap `grafana-dashboards` из `infra/grafana/dashboards/`):
  **Node Overview (hardware)** — CPU/RAM/диск/load/сеть узла;
  **Kubernetes / Application** — поды, рестарты, CPU/RAM подов, rps приложения;
  **WAF & Application logs (Loki)** — audit-события WAF, 4xx/5xx, живые логи;
  **Service Health (живость сервисов)** — UP/DOWN-панели по `up{job=...}` для
  Traefik/Gateway, Prometheus, Loki, Fluent Bit, Grafana, ноды (node-exporter),
  kubelet/cAdvisor, API server и подов full-proj (backend, waf, frontend,
  mysql — через `kube_pod_status_ready`);
- PVC 1Gi (local-path), login проверен, дашборды видны без ручных настроек;
  пароль админа хранится в БД Grafana (PVC): `GRAFANA_ADMIN_PASSWORD` задаёт
  его только при ПЕРВОЙ установке, смена пароля в UI сохраняется;
  `/metrics` Grafana отдаётся без авторизации (scrape-джоба без basic_auth).

Отдельные scrape-джобы для живости сервисов (static-конфиги в
`infra/prometheus/values.yaml`):

| Job | Target |
|---|---|
| `traefik` | `traefik-metrics.traefik.svc.cluster.local:9100` (entrypoint `metrics` чарта Traefik) |
| `loki` | `loki.logging.svc.cluster.local:3100` |
| `fluent-bit` | `fluent-bit.logging.svc.cluster.local:2020/api/v1/metrics/prometheus` |
| `grafana` | `grafana.monitoring.svc.cluster.local:80` |

## 3. Верификация (фактические результаты)

```bash
kubectl port-forward -n monitoring svc/prometheus-server 9090:80

# все цели живы
curl 'http://localhost:9090/api/v1/query?query=up' | jq '.data.result[] | {job: .metric.job, instance: .metric.instance, value: .value[1]}'
# node-exporter ... -> 1; kubernetes-pods instance=10.42.0.10:9113 -> 1; и т.д.

# метрики приложения: после обращений к приложению счётчик растёт
curl 'http://localhost:9090/api/v1/query?query=nginx_http_requests_total'
# {host="", status=""} -> N запросов (растёт после каждого curl к :30080)

# инфраструктурные метрики
curl 'http://localhost:9090/api/v1/query?query=node_memory_MemAvailable_bytes/1024/1024'
curl 'http://localhost:9090/api/v1/query?query=rate(container_cpu_usage_seconds_total[5m])'
```

Grafana (визуальная проверка):

```bash
curl -s http://localhost:30300/api/health            # {"database":"ok","version":"12.3.1",...}
# браузер: http://<node-ip>:30300 -> 3 готовых дашборда, логи за последние 30 мин в Loki-панелях
```

## 4. Роадмап

- HTTP-метрики Laravel (пакет `spatie/laravel-prometheus`): коды ответов, latency;
- алерты (Alertmanager), ServiceMonitor/operator при переносе на kube-prometheus-stack.
