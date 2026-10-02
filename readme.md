# full_proj — Laravel CMS + Next.js + WAF (ModSecurity) в Kubernetes

Веб-приложение на стеке **Laravel 10 + Filament CMS + Next.js + MySQL**, защищённое
WAF **ModSecurity + OWASP CRS**, с полным контуром по кейсу «MTC ENGINEER HACK»:

- **Kubernetes (k3s)** + **Gateway API (Traefik v3)** + **Prometheus** + **Fluent Bit → Loki**;
- локальная разработка — Docker Compose (`./setup.sh`).

Документация оформлена в подходе **spec-driven development** (требования → критерии
приёмки → реализация → верификация). Спецификации — в [`docs/`](docs/README.md).

---

## Состав решения и версии

| Компонент | Реализация / версия |
|---|---|
| Kubernetes | **k3s v1.36.5 (Kubernetes v1.36.5)**, containerd 2.3.4 — [SPEC-01](docs/specs/01-kubernetes.md) |
| Способ создания кластера | `curl -sfL https://get.k3s.io \| sh -s - --disable traefik --disable metrics-server` на Ubuntu 24.04 |
| ОС | **Ubuntu 24.04.5 LTS** (проверено; Docker-путь — любая ОС с Docker) |
| Gateway API | **Traefik v3.7.13** (Gateway API v1.5.1): GatewayClass `traefik`, Gateway `full-proj-gateway`, HTTPRoute `full-proj-route` → Service `waf` — [SPEC-03](docs/specs/03-gateway-api.md) |
| Веб-приложение | Laravel 10 (PHP 8.3), Filament 3, MySQL 8, Next.js 16 / React 19 — [SPEC-02](docs/specs/02-application.md) |
| Образы | собираются локально (`scripts/build-images.sh` → registry `localhost:5000`) или в GHCR (CI) |
| WAF | ModSecurity 3.0.17 + OWASP CRS 4.29.0 (`owasp/modsecurity-crs:nginx-alpine`) — [SPEC-06](docs/specs/06-waf.md), [waf/SPEC.md](waf/SPEC.md) |
| Мониторинг | Prometheus v3.15 + node-exporter + kube-state-metrics + nginx-exporter приложения — [SPEC-04](docs/specs/04-monitoring.md) |
| Логирование | Fluent Bit v5.1.3 (DaemonSet) → Loki v3.6.12 — [SPEC-05](docs/specs/05-logging.md) |
| Автоматизация | `scripts/build-images.sh` + `scripts/deploy.sh` (идемпотентно), CI/CD подготовлен — [SPEC-07](docs/specs/07-automation.md) |

---

## Быстрый старт (Kubernetes, Ubuntu 24.04)

```bash
# 0. Кластер k3s (один раз)
curl -sfL https://get.k3s.io | sh -s - --disable traefik --disable metrics-server
sudo cat /etc/rancher/k3s/k3s.yaml > ~/.kube/config && chmod 600 ~/.kube/config

# 1. Собрать образы в локальный registry
./scripts/build-images.sh

# 2. Секреты (из шаблона)
cp local-secrets.example.yaml local-secrets.yaml   # заполнить APP_KEY и пароли

# 3. Развернуть всё одной командой (Gateway API, WAF, приложение, Prometheus, Loki+Fluent Bit)
./scripts/deploy.sh
```

> ⚠️ Если на машине включён VPN с перехватом DNS/подсетей — отключите его
> (конфликт с сервисной сетью k3s, см. SPEC-01).

После развёртывания (вариант A — единая точка входа, весь трафик через WAF):

| Сервис | URL | Описание |
|---|---|---|
| Фронтенд | `http://localhost:30080/` | Next.js (за Gateway API + WAF) |
| Бэкенд | `http://localhost:30080/api`, `/admin`, `/storage` | nginx → Laravel (за WAF) |
| Админ-панель | `http://localhost:30080/admin` | Filament CMS |
| API | `http://localhost:30080/api` | JSON-эндпоинты |

## Быстрый старт (Docker Compose)

```bash
git clone <URL_РЕПОЗИТОРИЯ> && cd full_proj
chmod +x setup.sh && ./setup.sh
```

| Сервис | URL | Описание |
|---|---|---|
| Фронтенд | `http://localhost:3000` | Next.js |
| Бэкенд (через WAF) | `http://localhost:8080` | nginx → Laravel |
| Админ-панель | `http://localhost:8080/admin` | Filament CMS |
| API | `http://localhost:8080/api` | JSON-эндпоинты |

---

## Проверка работоспособности (k8s)

```bash
# 1. Gateway API + приложение
kubectl get gateway -n full-proj                    # PROGRAMMED: True
curl -s http://localhost:30080/api/news | head -c 200   # 200 + JSON

# 2. WAF: легитимный трафик проходит, атаки блокируются
./waf/tests/run-tests.sh http://localhost:30080     # 18/18
python3 waf/tests/ddos_static.py --url http://localhost:30080/favicon.ico  # 429
kubectl logs -n full-proj deploy/waf                # audit JSON с ruleId

# 3. Мониторинг
kubectl port-forward -n monitoring svc/prometheus-server 9090:80
curl 'http://localhost:9090/api/v1/query?query=up' | jq '.data.result[] | {job: .metric.job, value: .value[1]}'
curl 'http://localhost:9090/api/v1/query?query=nginx_http_requests_total'

# 4. Логирование (после обращения к приложению)
kubectl port-forward -n logging svc/loki 3100:3100
curl -G 'http://localhost:3100/loki/api/v1/query_range' --data-urlencode 'query={namespace="full-proj"}'
```

---

## Документация

- [`docs/README.md`](docs/README.md) — индекс спецификаций и архитектура;
- [`docs/passport.md`](docs/passport.md) — паспорт решения по структуре задания;
- [`docs/specs/`](docs/specs/) — спецификации разделов задания (01–09);
- [`waf/SPEC.md`](waf/SPEC.md) — детальная спецификация WAF;
- [`MIGRATION.md`](MIGRATION.md) — перенос репозитория на новый GitHub.

## Безопасность

В репозитории **нет** реальных паролей, токенов или ключей. Секреты передаются через
переменные окружения (`.env`), Kubernetes Secrets (`helm/templates/secrets.yaml`,
значения из `local-secrets.yaml` / CI-secrets) и GitHub Actions secrets. Подробнее —
[docs/specs/08-security.md](docs/specs/08-security.md).
