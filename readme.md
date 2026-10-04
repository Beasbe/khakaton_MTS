# full_proj — Laravel CMS + Next.js + WAF (ModSecurity) в Kubernetes

Веб-приложение на стеке **Laravel 10 + Filament CMS + Next.js + MySQL**, защищённое
WAF **ModSecurity + OWASP CRS**, с полным контуром по кейсу «MTC ENGINEER HACK»:

- **Kubernetes (k3s)** + **Gateway API (Traefik v3)** + **Prometheus** + **Fluent Bit → Loki** + **Grafana**;
- HTTPS (самоподписанный TLS, terminate на Gateway) + HTTP;
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
| Gateway API | **Traefik v3.7.13** (Gateway API v1.5.1): GatewayClass `traefik`, Gateway `full-proj-gateway` (HTTP :80 + HTTPS :443), HTTPRoute `full-proj-route` → Service `waf` — [SPEC-03](docs/specs/03-gateway-api.md) |
| TLS | самоподписанный сертификат (`scripts/gen-cert.sh` → Secret `full-proj-tls`), terminate на Gateway, WAF инспектирует расшифрованный трафик |
| Веб-приложение | Laravel 10 (PHP 8.3), Filament 3, MySQL 8, Next.js 16 / React 19 — [SPEC-02](docs/specs/02-application.md) |
| Образы | собираются локально (`scripts/build-images.sh` → registry `localhost:5000`) или в GHCR (CI) |
| WAF | ModSecurity 3.0.17 + OWASP CRS 4.29.0 (`owasp/modsecurity-crs:nginx-alpine`) — [SPEC-06](docs/specs/06-waf.md), [waf/SPEC.md](waf/SPEC.md) |
| Мониторинг | Prometheus v3.15 + node-exporter + kube-state-metrics + nginx-exporter приложения — [SPEC-04](docs/specs/04-monitoring.md) |
| Визуализация | **Grafana v12.3.1** (NodePort 30300): 4 дашборда (железо, k8s/приложение, WAF-логи, живость сервисов), Prometheus + Loki подключены автоматически |
| Логирование | Fluent Bit v5.1.3 (DaemonSet) → Loki v3.6.12 — [SPEC-05](docs/specs/05-logging.md) |
| Автоматизация | `scripts/build-images.sh` + `scripts/deploy.sh` + `scripts/gen-cert.sh` (идемпотентно), CI в GH Actions — [SPEC-07](docs/specs/07-automation.md) |

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

# 3. Развернуть всё одной командой (Gateway API HTTP+HTTPS, WAF, приложение,
#    Prometheus, Grafana, Loki+Fluent Bit)
./scripts/deploy.sh
```

> ⚠️ Если на машине включён VPN с перехватом DNS/подсетей — отключите его
> (конфликт с сервисной сетью k3s, см. SPEC-01). На ноутбуке с нестабильным
> Wi-Fi/DHCP зафиксируйте адрес ноды через `--node-ip` на dummy-интерфейсе
> (см. SPEC-01, Примечание 3) — тогда смена сети не требует рестарта k3s.

После развёртывания (вариант A — единая точка входа, весь трафик через WAF):

| Сервис | URL | Описание |
|---|---|---|
| Фронтенд | `https://localhost:30443/` | Next.js (за Gateway API + WAF); `http://localhost:30080/` автоматически редиректит сюда |
| Бэкенд | `https://localhost:30443/api`, `/admin`, `/storage` | nginx → Laravel (за WAF) |
| Админ-панель | `https://localhost:30443/admin` | Filament CMS |
| API | `https://localhost:30443/api` | JSON-эндпоинты |
| Grafana | `http://localhost:30300` | дашборды метрик и логов (логин `admin`; пароль задаётся при развёртывании через `GRAFANA_ADMIN_PASSWORD`) |
| Argo CD (GitOps) | `http://localhost:30444` | сверка кластера с репозиторием (пароль — из Secret, команда ниже) |

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

## Эндпоинты и доступ к сервисам (k8s)

### Через Gateway API :30080 (единая точка входа, всё за WAF)

| Сервис | URL | Что вернёт |
|---|---|---|
| Фронтенд | `http://localhost:30080/` | страницы Next.js (лента, проекты, контакты) |
| API — новости | `http://localhost:30080/api/news` | `{"success":true,"data":[...]}` |
| API — проекты | `http://localhost:30080/api/projects` | JSON со списком проектов |
| Админ-панель | `http://localhost:30080/admin` | перед логином, создайте пользака командой ниже |
| Хранилище | `http://localhost:30080/storage/...` | загруженные файлы |
| Healthcheck WAF | `http://localhost:30080/healthz` | `OK` (отвечает сам WAF, не проксируется) |
| Метрики WAF | `http://localhost:30080/metrics/nginx` | stub_status nginx WAF; по умолчанию **403** — открывается через `METRICS_ALLOW_FROM` (env пода waf) |

Создание пользователя для админки (интерактивно — имя, email, пароль):

```bash
kubectl exec -it -n full-proj deploy/backend -c backend -- php artisan make:filament-user
```

### Внутренние сервисы (вход по желанию через port-forward)

Все сервисы ниже — ClusterIP (снаружи не доступны). Для входа пробросьте порт:

| Сервис | Команда | URL после проброса | Примечание |
|---|---|---|---|
| Prometheus UI | `kubectl port-forward -n monitoring svc/prometheus-server 9090:80` | `http://localhost:9090` | Graph: `up`, `nginx_http_requests_total`, `node_memory_MemAvailable_bytes` |
| Prometheus API | (тот же проброс) | `http://localhost:9090/api/v1/query?query=up` | программные запросы |
| Loki (логи) | `kubectl port-forward -n logging svc/loki 3100:3100` | `http://localhost:3100` | API: `/loki/api/v1/query_range`; liveness `/ready`; метрики `/metrics` |
| Fluent Bit | `kubectl port-forward -n logging svc/fluent-bit 2020:2020` | `http://localhost:2020/api/v1/metrics/prometheus` | метрики самого сборщика |
| Traefik API (диагностика) | `kubectl port-forward -n traefik deploy/traefik 8080:8080` | `http://localhost:8080/api/http/routers` | список роутеров/бэкендов Gateway API |
| MySQL | `kubectl port-forward -n full-proj svc/mysql 3306:3306` | `localhost:3306` | пароль в Secret `app-secrets` (только при необходимости) |
| WAF напрямую (диагностика) | `kubectl port-forward -n full-proj svc/waf 8081:8080` | `http://localhost:8081` | в обход Gateway — проверить WAF отдельно |
| nginx бэкенда напрямую | `kubectl port-forward -n full-proj svc/nginx 8082:80` | `http://localhost:8082` | в обход WAF (диагностика) |
| node-exporter | `kubectl port-forward -n monitoring svc/prometheus-prometheus-node-exporter 9100:9100` | `http://localhost:9100/metrics` | метрики узла (CPU/RAM/диск) |

---

## Подключение к сервисам (port-forward)

`kubectl port-forward` **блокирует терминал** — выполняйте запросы во втором
терминале или пользуйтесь однострочниками с фоновым порт-форвардом (`&` +
`kill %1`) из раздела проверки ниже. Подключайтесь к **сервисам** (`svc/...`),
чтобы не вычислять имя пода. Имена подов по меткам:

```bash
kubectl get pods -n logging    -l app.kubernetes.io/name=fluent-bit
kubectl get pods -n monitoring -l app.kubernetes.io/name=prometheus-node-exporter
kubectl get pods -n monitoring -l app.kubernetes.io/name=kube-state-metrics
```

| Сервис | Команда | Что смотреть |
|---|---|---|
| Приложение + WAF | — | `https://localhost:30443/` (HTTP `:30080` → 302-редирект), `/admin`, `/api` |
| Grafana | — | `http://localhost:30300` (NodePort): дашборды «Node Overview», «Kubernetes / Application», «WAF & Application logs», «Service Health» |
| Argo CD | — | `http://localhost:30444` (NodePort): Application `full-proj` — sync-статус, дрейф кластера |
| Traefik Dashboard | `kubectl port-forward -n traefik deploy/traefik 8080:8080` | `http://localhost:8080/dashboard/` |
| Prometheus | `kubectl port-forward -n monitoring svc/prometheus-server 9090:80` | `http://localhost:9090` |
| node-exporter | `kubectl port-forward -n monitoring svc/prometheus-prometheus-node-exporter 9100:9100` | `http://localhost:9100/metrics` |
| kube-state-metrics | `kubectl port-forward -n monitoring svc/prometheus-kube-state-metrics 8180:8080` | `http://localhost:8180/metrics` |
| Fluent Bit (метрики) | `kubectl port-forward -n logging svc/fluent-bit 2020:2020` | `http://localhost:2020/api/v1/metrics/prometheus` |
| Loki | `kubectl port-forward -n logging svc/loki 3100:3100` | `http://localhost:3100/ready`, запросы LogQL |

## Проверка работоспособности (k8s)

```bash
# 1. Gateway API + приложение (HTTP и HTTPS)
kubectl get gateway -n full-proj                    # PROGRAMMED: True (listeners http:80, https:443)
curl -s -o /dev/null -w '%{http_code} -> %{redirect_url}\n' http://localhost:30080/api/news   # 302 -> https://localhost:30443/...
curl -sk https://localhost:30443/api/news | head -c 200   # 200 + JSON (TLS-terminate на Gateway)

# 2. WAF: легитимный трафик проходит, атаки блокируются (по HTTPS)
./waf/tests/run-tests.sh https://localhost:30443    # 18/18
python3 waf/tests/ddos_static.py --url https://localhost:30443/favicon.ico --insecure  # 429
kubectl logs -n full-proj deploy/waf                # audit JSON с ruleId

# 3. Мониторинг (порт-форвард в фоне, в конце — kill %1)
kubectl port-forward -n monitoring svc/prometheus-server 9090:80 &
sleep 2
curl -s 'http://localhost:9090/api/v1/query?query=up' | jq '.data.result[] | {job: .metric.job, value: .value[1]}'
curl -s 'http://localhost:9090/api/v1/query?query=nginx_http_requests_total'
kill %1

# 3b. Grafana: http://localhost:30300 — дашборды метрик и логов
curl -s http://localhost:30300/api/health           # {"database":"ok","version":"12.3.1",...}

# 4. Логирование (после обращения к приложению)
kubectl port-forward -n logging svc/loki 3100:3100 &
sleep 2
curl -s -G 'http://localhost:3100/loki/api/v1/query_range' --data-urlencode 'query={namespace="full-proj"}' | jq '.data.result[].stream'
kill %1
```

## HTTPS (самоподписанный сертификат)

HTTPS-точка входа `https://<node-ip>:30443`: TLS терминируется на Gateway
(Traefik), сертификат — самоподписанный, из Secret `full-proj-tls`
(генерируется `scripts/gen-cert.sh`, SAN: `localhost`, `127.0.0.1`,
`192.168.200.1`; можно добавить IP аргументами). Браузер покажет
предупреждение о недоверенном CA — нажмите «Дополнительно → Перейти»;
для CLI используйте `curl -k`. WAF инспектирует и HTTPS-трафик (TLS снят до
WAF). Фронтенд собран с относительными URL — работает по обоим протоколам.

**HTTP → HTTPS:** листенер `http` (:30080) отдаёт `302` на
`https://<host>:30443/...` (HTTPRoute `full-proj-http-redirect` с фильтром
`RequestRedirect`); приложение прикреплено только к HTTPS-листенеру, так
что весь прикладной трафик гарантированно идёт по TLS и через WAF.

---

## DevSecOps

- **Gitleaks** в CI (джоба `secrets`): сканирование секретов во всей git-истории;
  локально: `gitleaks detect --source .` (или через Docker). Проверено: 79 коммитов — утечек нет.
- **Секреты — SOPS + age (helm-secrets-подход)**: в git лежит ТОЛЬКО зашифрованный
  `helm/secrets/dev.yaml` (правила в `.sops.yaml`); расшифровывается в deploy.sh
  (локально — ключ из `~/.config/sops/age/keys.txt`, в CI/CD — Secret `SOPS_AGE_KEY`).
  Пароли в репозиторий/README/values НЕ попадают:

  ```bash
  # Argo CD: пароль генерируется при первом запуске
  kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d

  # Grafana: задаётся при развёртывании (обязательная переменная)
  GRAFANA_ADMIN_PASSWORD=... ./scripts/deploy.sh
  ```

- **Argo CD (GitOps)**: кластер непрерывно сверяется с репозиторием — Application
  `full-proj` (`argocd/application.yaml`) разворачивает чарт `helm/` из ветки `main`;
  `selfHeal` откатывает любые ручные изменения в кластере, `prune` удаляет лишнее.
  Секреты в git не попадают: `app-secrets` создаётся вне git (deploy.sh из
  sops-файла / `local-secrets.yaml`, чарт при `secrets.existingSecret=true` его не трогает).
  Образы приложения — ghcr.io с тегом = git SHA коммита; WAF зафиксирован по диджесту.
  UI: `http://localhost:30444`.
  Демо дрейфа: `kubectl scale deployment backend -n full-proj --replicas=3` →
  Argo CD в течение минуты вернёт 1 реплику (как в чарте).

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
