# serial.md — журнал проблем и решений (k3s-стенд)

Формат: **дата → проблема → гипотеза/причина → решение → статус.**
Ведётся после каждого теста. `[TODO]` — открытые вопросы.

---

## 2026-10-02 (день 2) — развёртывание полного контура кейса на k3s

### 1. Helm-репозитории недоступны / таймауты
- **Проблема:** `helm repo add prometheus-community` → `context deadline exceeded`
  (index.yaml у prometheus-community ~45 МБ, helm не вытягивал).
- **Решение:** перейти на OCI-артефакты напрямую из ghcr.io
  (`oci://ghcr.io/prometheus-community/charts/prometheus` и т.д.).
  Все чарты в `scripts/deploy.sh` теперь OCI — быстрее и воспроизводимее.
- **Статус:** ✅ решено (зафиксировано в deploy.sh).

### 2. Traefik-чарт v41: серия ошибок валидации values
- `providers.kubernetesGateway.experimentalChannel: standard` → схема ждёт **boolean**
  (в чарте v41 флаг рендерится только при `true`).
- Встроенный Gateway чарта (listener 8000) конфликтовал с нашим портом 80 →
  `gateway.enabled: false`, Gateway создаём сами в нашем чарте.
- Чарт сам создаёт GatewayClass `traefik` (controllerName `traefik.io/gateway-controller`)
  с helm-метками → мой ручной GatewayClass мешал (helm не может импортировать).
  Решение: удалить свой манифест, GatewayClass владеет чарт.
- **Статус:** ✅ решено.

### 3. WAF: `MODSEC_RULE_ENGINE: On` → YAML bool
- **Проблема:** K8s API: `cannot unmarshal bool into EnvVar.value` — YAML 1.1 трактует
  `value: On` как boolean.
- **Решение:** `| quote` в шаблоне (`value: "On"`).
- **Статус:** ✅ решено (helm/templates/waf.yaml).

### 4. WAF-под в CrashLoop: `host not found in upstream "nginx"`
- **Причина-1:** CoreDNS в k3s v1.36.5 стартует **без env
  KUBERNETES_SERVICE_HOST/PORT** → плагин kubernetes не видит сервисы → NXDOMAIN на всё.
- **Решение:** идемпотентный patch deployment coredns в `scripts/deploy.sh`
  (env + `kubernetes svc` ClusterIP).
- **Причина-2 (главная):** включённый **VPN** на ноутбуке: policy-routing
  (`ip rule`: таблица 2022/tun0) перехватывал **весь трафик на порт 53** и подсеть
  **10.43.0.0/16** (совпадает с сервисной сетью k3s!) → DNS-ответы NXDOMAIN из туннеля.
- **Решение:** отключить VPN на время работы со стендом (зафиксировано в SPEC-01).
- **Статус:** ✅ решено.

### 5. Loki: валидация SingleBinary
- `read/write replicas` надо явно обнулить (`read.replicas: 0` и т.д.) + отключить
  canary/gateway/ruler/memcached-кэши (экономия RAM).
- **Статус:** ✅ решено.

### 6. Loki: `mkdir /var/loki: read-only file system`
- При `singleBinary.persistence.enabled: false` чарт вообще не монтирует volume
  в /var/loki, а rootfs контейнера read-only.
- **Решение:** `persistence.enabled: true, size: 2Gi` (local-path PVC).
- **Подводный камень:** `volumeClaimTemplates` неизменяемы → пришлось
  `helm uninstall loki && helm install` (релиз был в статусе failed).
- **Статус:** ✅ решено.

### 7. Prometheus-чарт v29: дубли job_name `prometheus`
- `extraScrapeConfigs` добавляются ПОСЛЕ дефолтных `scrapeConfigs` чарта → коллизия.
- **Решение:** убрать extraScrapeConfigs, использовать нативные `scrapeConfigs`
  (добавил только `node-exporter`). nginx-exporter приложения подхватывается
  дефолтной джобой `kubernetes-pods` по аннотациям.
- Отдельный релиз prometheus-node-exporter удалил: конфликт hostPort 9100
  со встроенным subchart'ом чарта Prometheus.
- `pushgateway.enabled` не работал — правильный ключ `prometheus-pushgateway.enabled`.
- **Статус:** ✅ решено.

### 8. Админка `/admin`: редирект на `http://localhost:8080/admin/login` (долго!)
- **Симптом:** логин-страница грузится, но все asset-URL и Location — `localhost:8080`.
- **Разбор:** редирект оказался request-driven (не app.url): прямой запрос в nginx
  показывал host из заголовков. Через Gateway приложение видело `Host: localhost`
  и `X-Forwarded-Port: 8080`.
- **Корень:** WAF (owasp/modsecurity-crs): `proxy_set_header Host $host`
  (**nginx `$host` режет порт!**) + `X-Forwarded-Port $server_port` (=8080, порт WAF).
  Приложение (TrustProxies) собирало корень `http://localhost:8080`.
  В Compose это совпадало с APP_URL случайно.
- **Решение:** в WAF: `PROXY_HOST_HEADER=$http_host`,
  `NGINX_X_FORWARDED_PORT=$http_x_forwarded_port` (helm + docker-compose).
- **Попутно найдено:** в образ backend зашивались `.env` (APP_URL=8080, DB-креды)
  и `database/database.sqlite`; php-fpm как PID 1 теряет env контейнера
  (environ пустой/испорченный) → Laravel читал .env из образа.
- **Решение:** генерация `.env` из env пода при старте (command в backend.yaml)
  + `CMS/.dockerignore` (.env, **/*.sqlite, bootstrap/cache/*.php, vendor).
- **Подводные камни сборки:**
  - правка .dockerignore **не инвалидирует кеш COPY-слоя** → нужен `--no-cache`;
  - в .dockerignore `*.sqlite` не матчит вложенные пути (Go filepath.Match:
    `*` не пересекает `/`) → `**/*.sqlite`;
  - исключать `bootstrap/cache/*` и `storage/*` целиком нельзя — ломает
    `composer install` (artisan не может писать) → только `bootstrap/cache/*.php`;
  - Helm схлопнул `\$$` → `$$` (PID шелла!) → в .env мусор `APP_URL="1v"` →
    заменил eval на `val=$(printenv "$v")`.
- **Статус:** ✅ решено (после фикса WAF редирект/ассеты должны быть `localhost:30080`).

### 9. После смены Wi-Fi (10.4.17.209 → 192.168.1.217) — Prometheus цели DOWN
- node-exporter и kube-state-metrics в CrashLoopBackOff: **liveness-пробы бьют по
  старому IP ноды** (hostNetwork поды) → "network is unreachable".
- kubelet/apiserver-цели скрейпятся по устаревшему InternalIP ноды
  (k3s не обновляет node IP без рестарта).
- **Предполагаемое решение (ещё не применено):**
  1) `sudo systemctl restart k3s` — перерегистрация ноды с актуальным IP;
  2) пробы node-exporter на `127.0.0.1` (hostNetwork → переживёт смену сети);
  3) kube-state-metrics — проверить логи после стабилизации сети
     (умер молча, exit code 2, после "Tested communication with server").
- **Статус:** ⚠️ частично: WAF/приложение починены, мониторинг ждёт рестарта k3s.

---

## 2026-10-02 — Traefik Gateway API перестал строить маршруты (ОТКРЫТО)

### Симптом
После рестарта traefik-пода `curl http://localhost:30080/*` → **404 от самого Traefik**
(раньше работало). В `/api/http/routers` — только `*@internal`, ни одного gateway-маршрута.
Новый тестовый Gateway в namespace traefik → статус **"Waiting for controller"**.

### Что уже проверено (всё «правильно»):
- ✅ провайдер kubernetesGateway стартует, in-cluster клиент (env на месте);
- ✅ RBAC: get/list/watch на все gateway-ресурсы + status/update (can-i = yes);
- ✅ CRD Gateway API v1.5.1 применены целиком;
- ✅ GatewayClass `traefik` (controllerName `traefik.io/gateway-controller`) — Accepted;
- ✅ Gateway/HTTPRoute: Accepted + ResolvedRefs + Programmed (старые условия);
- ✅ DNS из traefik-пода работает; reflector-ошибок нет;
- ⚠️ **GatewayClass status "Handled by Traefik controller" имеет старый timestamp
  (11:36:06Z)** — провайдер НЕ выполняет `loadConfigurationFromGateways`
  (иначе бы обновлял статус на каждом событии);
- ❌ `experimentalChannel: true/false` — эффекта нет; DEBUG-логи — провайдер молчит
  после "Starting provider".

### Гипотезы (по убыванию вероятности)
1. **Смена сети сломала что-то на уровне кластера** (события informer'ов не доходят) —
   лечится рестартом k3s.
2. Несовместимость **traefik v3.7.13 + Gateway API v1.5.1** (свежак): старый под
   работал на CRD v1.2.1. Проверить: откат CRD до v1.2.1 или пин traefik v3.6.x.
3. Тайная проблема с событиями informer'ов (все кеши пустые) — нужен тест:
   создать/удалить Gateway и смотреть DEBUG-логи.

### План проверок (следующие шаги)
1. `sudo systemctl restart k3s` (перерегистрация ноды после смены Wi-Fi) + повторный
   `./scripts/deploy.sh` — заодно чинит п.9 (Prometheus).
2. Если не поможет — откат CRD на v1.2.1 + рестарт traefik.
3. Если не поможет — `helm uninstall traefik` и чистая переустановка.
4. Если не поможет — пин traefik до v3.6 (известно-рабочей).

> Важно: вариант A (см. ниже) Traefik **не чинит** — проверено тестовым whoami-роутом:
> провайдер не строит вообще ни одного маршрута, дело не в бэкенде HTTPRoute.

---

## 2026-10-02 — Вариант A: единая точка входа, WAF перед фронтендом и бэкендом

### Цель
Раньше фронтенд Next.js отдавался напрямую через NodePort :30560 мимо WAF
(диаграмма честно показывала это пунктиром). Вариант A: убрать NodePort фронтенда,
весь трафик — через Gateway :30080 -> WAF, который сам маршрутизирует по path.

### Реализация
- WAF-шаблон: `map $uri $waf_upstream` — первое совпадение побеждает:
  `default -> фронтенд`; `/api/contact -> фронтенд`; `/api/, /admin, /storage/,
  /sanctum/, /livewire/, /filament/, /css/, /js/, /vendor/ -> бэкенд`
  (ассеты админки /css,/js,/vendor лежат в корне Laravel — учтено!).
- Переменный `proxy_pass $waf_upstream` — инспекция ModSecurity идёт для ВСЕХ
  запросов, а лимит статики (limit_req) — для статики обоих приложений.
- `frontend` Service -> ClusterIP (NodePort :30560 удалён), CORS — один origin `:30080`.

### Проблемы по пути
1. **`resolver directive is duplicate`** — образ owasp сам пишет resolver в http-контекст
   (91-update-resolver.sh берёт nameserver из /etc/resolv.conf → CoreDNS).
   Свой resolver убрал.
2. **502 на всё** после перехода на переменный proxy_pass: nginx resolver
   **не раскрывает search-домены** — короткое имя `nginx` не резолвится.
   Решение: FQDN в map (`http://nginx.<ns>.svc.cluster.local:80`,
   `http://frontend.<ns>.svc.cluster.local:3000`).

### Результат теста (через svc/waf port-forward, без Traefik)
- `/` -> 200 + Next.js HTML (5 маркеров `_next`) — фронтенд за WAF;
- `/api/news` -> 200 JSON (бэкенд); `/admin` -> 302 (логин);
- `/css/filament/filament/app.css` -> 200 (ассеты админки идут в бэкенд);
- `POST /api/contact` -> 500 (пустые SMTP-креды в local-secrets.yaml — не роутинг);
- sqlmap UA -> 403, SQLi -> 403 ✅; favicon.ico -> 404 (у фронтенда нет favicon.ico — косметика).

### Осталось
- ~~Перезапустить k3s (sudo) — Traefik не строит маршруты~~ — **РЕШЕНО** (см. ниже);
- ~~Проверить end-to-end через :30080 после рестарта~~ — ✅ 18/18;
- Обновить docs (README, SPEC-03/06) — ✅ сделано.

---

## 2026-10-02 — РЕШЕНО: Traefik строит маршруты после рестарта k3s

### Причина (гипотеза №1 подтвердилась)
После `sudo systemctl restart k3s` (перерегистрация ноды с новым IP
192.168.1.217) провайдер kubernetesgateway начал получать события и построил
все маршруты. До рестарта: GatewayClass status не обновлялся (stale 11:36Z),
ни одного роутера; после — роутеры появились, Gateway PROGRAMMED с новым адресом.
Вывод: смена сети Wi-Fi ломает клиентские соединения informer'ов провайдера
(не Traefik-баг и не CRD-версия).

### Инцидент 2: whoami-тест перехватил весь трафик :30080
Отладочные test-gw/test-route/whoami (из диагностики) после оживления Traefik
стали обслуживать ВСЕ запросы на entrypoint web (PathPrefix `/` без matches
матчит всё, приоритет оказался у тестового роута). Симптом: `/` отвечал
`Hostname: whoami-...`, WAF-тесты 5/13, «атаки» получали 200 от whoami.
**Решение:** удалить тестовые ресурсы (httproute/gateway/deployment/service).
**Урок:** отладочные Gateway API-ресурсы удалять сразу после диагностики.

### Инцидент 3: ConfigMap WAF не перечитывается подом
Правка `waf-nginx-template` (правило favicon) не доехала до пода: образ owasp
рендерит конфиг один раз при старте (envsubst), ConfigMap не вотчится.
**Решение:** `kubectl rollout restart deployment waf` после изменения ConfigMap
(записать в SPEC/README).

### Финальное состояние (всё ✅ через :30080)
- WAF-тесты **18/18** (легитимный трафик 200, сканеры/CRS-атаки 403);
- DDoS: 192 из 400 запросов к статике -> **429**;
- фронтенд Next.js — за WAF (5 маркеров `_next`);
- `/admin` -> редирект `http://localhost:30080/admin/login` ✅;
- Prometheus: **11/11 целей UP** (node-exporter, kube-state-metrics,
  nginx-exporter, kubelet, apiserver — вылечились перерегистрацией IP);
- Loki: access-логи backend/waf поступают сразу после запроса;
- 13 подов Running, Gateway PROGRAMMED (адрес 192.168.1.217).

### Открытые мелочи
- `/api/contact` -> 500: пустые SMTP-креды в local-secrets.yaml (не баг роутинга);
- k3s-рестарт после смены сети — обязательный шаг для ноутбучного стенда
  (добавить в SPEC-01/README);
- favicon.ico в репо — 0 байт (косметика, отдаётся 200).

---
## Сессия 2026-10-03: смена Wi-Fi + баг «детальные страницы = 404»

### Инцидент 4: после смены сети кластер снова «поехал»
Ноутбук сменил Wi-Fi: IP ноды `192.168.1.217` -> `10.4.24.192`.
Симптомы: kube-state-metrics и node-exporter в CrashLoopBackOff (47/48
рестартов), нода оставалась на старом INTERNAL-IP.
**Решение (повторное):** `sudo systemctl restart k3s` -> нода Ready с новым
IP, все поды Running. Это уже задокументированный обязательный шаг после
смены сети — подтверждён второй раз.
**Урок:** проверять `kubectl get nodes -o wide` сразу после смены сети,
не гоняя сначала приложение.

### Инцидент 5 (ГЛАВНЫЙ БАГ): /news/<slug> и /projects/<slug> -> 404
Симптом: список новостей/проектов работает (данные из БД видны), но
конкретная новость/проект — 404 (отдаёт notFound() внутри Next.js).
Диагностика по логам пода фронтенда при запросе детальной страницы:
`TypeError: fetch failed ... code: 'ECONNREFUSED'`.
**Корень:** детальные страницы — серверные компоненты (SSR). В образ был
вшит `NEXT_PUBLIC_API_URL=http://localhost:30080`, поэтому SSR-запрос из
контейнера фронтенда уходил на `localhost:30080` — а это САМ под фронтенда
(порт 30080 внутри контейнера не слушается) -> ECONNREFUSED -> fallback на
статику -> slug в статике нет -> notFound() -> 404.
Списки работали, потому что они клиентские ('use client') — fetch шёл из
браузера на хосте, где localhost:30080 валиден.
**Решение:** разделить URL бэкенда на два:
- `NEXT_PUBLIC_API_URL` (публичный, для браузера) — как было;
- `BACKEND_INTERNAL_API_URL` (внутрикластерный, для SSR) —
  `http://waf.full-proj.svc.cluster.local:8080` (вариант A: серверные
  запросы тоже идут через WAF).
В `src/lib/api.ts` и `apiProjects.ts` добавлена функция `apiBaseUrl()`:
на сервере (`typeof window === 'undefined'`) используется внутренний URL,
в браузере — публичный. URL картинок остались на публичном базовом URL
(они рендерятся в браузере).
Затронуто: api.ts, apiProjects.ts, helm/values.yaml
(`frontend.internalApiUrl`), helm/templates/frontend.yaml (env), compose
(env `BACKEND_INTERNAL_API_URL=http://waf:8080`), env.local.example.
**Перезапуск:** пересборка образа фронтенда (типчек ок), push в
localhost:5000, `crictl rmi` закешированного образа (иначе IfNotPresent
возьмёт старый), helm upgrade, новый под.
**Результат:** `/news/cuiu-cuiu-ia-kacuiu` -> 200 и рендерит контент из БД
(«Чую чую я качую»), `/projects/my-little-pony` -> 200, WAF-тесты 18/18,
логи фронтенда чистые.
**Урок:** при SSR в k8s `localhost`/NodePort из контейнера недоступен —
всегда нужен внутрикластерный адрес; для отладки такой мимикрии смотреть
логи пода при запросе, а не только коды ответов.
## Сессия 2026-10-03 (вечер): Wi-Fi флапает — привязка k3s к dummy-интерфейсу

### Инцидент 6: кампусный Wi-Fi меняет IP каждые ~10 минут -> кластер деградирует
Симптомы (после фикса 404 уже был запушен):
- kube-state-metrics CrashLoopBackOff: `Get https://10.43.0.1:443/version:
  dial tcp 10.43.0.1:443: connect: no route to host`;
- node-exporter убивается liveness-пробой: kubelet бьёт в протухший IP ноды
  (`http://192.168.1.217:9100` -> `http://10.4.24.192:9100` -> ...);
- при этом приложение работало (pod->ClusterIP приложения живёт на cni0).
Диагностика: Wi-Fi BMSTU_KAMPUS выдавал новый lease при каждой
переассоциации: 192.168.1.217 -> 10.4.24.192 -> 10.4.8.48 -> 10.4.18.36.
k3s регистрировал старый INTERNAL-IP; kube-proxy (в k3s v1.36 —
nftables-режим) DNAT'ил kubernetes-сервис на исчезнувший IP ноды ->
шлюз отвечал "no route to host". Endpoints/i-nft-правила при этом были
"свежими" — проверка `nft list ruleset` показала dnat на старый IP.
**Решение (ПОСТОЯННОЕ):** привязать ноду к стабильному адресу, не
зависящему от Wi-Fi:
1. Dummy-интерфейс через NetworkManager (переживает ребут):
   `nmcli con add type dummy con-name k3sip0 ifname k3sip0 \
    ipv4.addresses 192.168.200.1/32 ipv4.method manual connection.autoconnect yes`
2. В /etc/systemd/system/k3s.service к флагам добавлен
   `--node-ip 192.168.200.1` (в конец ExecStart), daemon-reload + restart.
Результат: нода INTERNAL-IP=192.168.200.1, DNAT kubernetes-сервиса ->
192.168.200.1:6443 (локальный, всегда доступен), ksm/node-exporter
Running, Prometheus 11/11 UP, WAF 18/18, Loki пишет.
Внешний доступ НЕ изменился: NodePort 30080 слушает на всех интерфейсах
(localhost:30080 работает, а также по Wi-Fi IP для других устройств).
**Урок:** на ноутбуке с кампусным Wi-Fi всегда фиксировать --node-ip на
dummy/мостовом интерфейсе; "restart k3s после смены сети" теперь НЕ нужен.
## Сессия 2026-10-03 (ночь): документация портов + CI

### Что сделано
- README: раздел «Подключение к сервисам» — port-forward по СЕРВИСАМ
  (svc/prometheus-server 9090:80, svc/loki 3100:3100, svc/fluent-bit
  2020:2020, svc/prometheus-prometheus-node-exporter 9100:9100,
  deploy/traefik 8080:8080 -> /dashboard/), метки подов и однострочники
  с фоновым порт-форвардом (kill %1).
  Ошибка юзера: `\|` внутри $() (в bash внутри $() пайп НЕ экранируется)
  и curl до готовности port-forward — теперь в доке рабочие команды.
- CI: .github/workflows/ci.yml — helm lint + buildx-сборка backend/frontend
  + push в GHCR (:latest, :sha); авто на push/PR (в PR без push).
  CD: deploy.yml переведён на workflow_dispatch (CD — принимающая сторона).

### Инцидент 7: GHCR 'repository name must be lowercase'
Первый прогон CI упал: repo `khakaton_MTS` содержит заглавные — GHCR
отклоняет такие имена образов.
**Решение:** шаг «Compute lowercase repository path» (tr '[:upper:]'
'[:lower:]' -> GITHUB_OUTPUT) в ci.yml и deploy.yml; SPEC-09 обновлён.
**Результат:** CI зелёный (checks+build), образы в GHCR, анонимный
docker pull ghcr.io/beasbe/khakaton_mts/{backend,frontend}:latest работает
(пакеты связаны с публичным репо). Variable NEXT_PUBLIC_API_URL задана
через gh variable set (= http://localhost:30080) — проверено, что URL
вшит в бандл (.next/static).
- Зависшие старые CD-раны (queued на несуществующий runner) отменены.
**Урок:** GHCR lowercase обязателен; gh-токен без read:packages — для
управления видимостью пакетов нужен `gh auth refresh -s read:packages`
или UI (нам не понадобилось — анонимный pull уже работал).
## Сессия 2026-10-03 (финал): Grafana, TLS, паспорт

### Что сделано
- **Grafana v12.3.1** (NodePort 30300): datasources Prometheus+Loki
  провайзятся автоматически; 3 дашборда из ConfigMap (infra/grafana/
  dashboards): Node Overview (железо), Kubernetes/Application (поды,
  рестарты, CPU/RAM, rps), WAF & Application logs (Loki). Проверено:
  /api/health ok, дашборды видны, Loki-запрос через Grafana вернул 100
  строк логов за 30 мин. Пароль: admin / GRAFANA_ADMIN_PASSWORD (дефолт
  admin, задаётся при deploy).
- **HTTPS самоподписанный**: Gateway listener https:443 (TLS Terminate,
  certificateRefs -> Secret full-proj-tls), Traefik entrypoint websecure
  (NodePort 30443), scripts/gen-cert.sh (идемпотентный, SAN localhost +
  127.0.0.1 + 192.168.200.1). Фронтенд переведён на ОТНОСИТЕЛЬНЫЕ URL
  (NEXT_PUBLIC_API_URL=""), чтобы работать по HTTP и HTTPS без mixed
  content. Проверено: https://localhost:30443 200, атака на HTTPS -> 403.
- Паспорт: добавлена страница «Запуск (для проверяющего)» + таблица точек
  входа; README: HTTPS-раздел, Grafana, исправлены сломанные pod/$(...)
  команды на svc-форварды.

### Инцидент 8: потерян helm-релиз full-proj (моя ошибка)
При разблокировке залипшего релиза удалил ВСЕ release-secrets (v6..v15),
а не только pending. Релиз исчез, ресурсы остались (PVC mysql-pvc с
данными не тронут).
**Восстановление без потери данных:** mysqldump (--no-tablespaces,
PROCESS-привилегии у юзера нет) -> helm install --force (revision 1,
failed — "cannot re-use a name" на повторе, PVC пережил) -> helm upgrade
(deployed, revision 2) -> данные на месте (новость «Чую чую...» жива).
**Урок:** удалять pending-секрет ТОЛЬКО по label status=pending-upgrade
(добавлено в deploy.sh: PENDING_RELEASE unlock); НИКОГДА не чистить все
release-secrets. helm v3.21 без команды adopt.

### Инцидент 9: EAI_AGAIN из фронтенда при живом nslookup
SSR-фетч падал с AbortError/EAI_AGAIN, хотя nslookup waf... резолвился.
Node (getaddrinfo) делает AAAA-запрос — старый под CoreDNS (25ч, netns
со времён прошлого IP) отвечал только на A. nslookup запрашивал только A,
поэтому «всё работало». **Решение:** kubectl rollout restart deployment
coredns -> свежий netns -> 200.
**Урок:** на ноутбуке после смены сети/рестартов k3s рестартовать ВСЕ
долгоживущие поды kube-system (coredns, svclb) — у них те же проблемы
netns, что у node-exporter/ksm ранее; DNS диагностировать через
`node -e "fetch(...)"`, а не nslookup (AAAA vs A).
## Дополнение: HTTP -> HTTPS редирект
Пользователь заметил: фронт всё ещё открывается по http. TLS был настроен
(листенер https:443 + Secret full-proj-tls), но HTTP-листенер просто
оставался рабочим параллельно.
**Решение:** HTTPRoute full-proj-http-redirect на листенере http с фильтром
RequestRedirect (scheme=https, port=30443); основной маршрут прикреплён
ТОЛЬКО к https. Теперь http://localhost:30080/* -> 302 на
https://localhost:30443/*, до WAF HTTP не доходит.
**Тесты переведены на HTTPS:** run-tests.sh (code() с -k),
ddos_static.py (--insecure). 18/18 и 429 проверены на :30443.
## Инцидент 10: после HTTP->HTTPS редиректа сломался /admin
Симптом: https://localhost:30443/admin отвечал 302 на
http://localhost:30443/admin/login (http!), переход по ссылке -> 404
(«Client sent an HTTP request to an HTTPS server» на Traefik).
**Корень (две причины в цепочке):**
1. WAF передавал X-Forwarded-Proto = $scheme (дефолтный env образа
   owasp/modsecurity-crs), а до WAF трафик после TLS-terminate всегда
   http -> Laravel видел схему http;
2. nginx бэкенда не пробрасывал X-Forwarded-* в php-fpm (в конфиге был
   жёсткий `fastcgi_param HTTPS off;`).
TrustProxies в Laravel уже был настроен ('*', X-Forwarded-*).
**Решение:** waf.nginxForwardedProto="$http_x_forwarded_proto" (env пода
WAF) + проброс X-Forwarded-Proto/Host/Port/For и HTTPS=$http_x_forwarded_proto
в fastcgi-блок nginx бэкенда (k8s ConfigMap helm/templates/nginx.yaml и
compose CMS/docker/nginx/default.conf).
**Проверка:** /admin -> 302 на https://.../admin/login -> 200; ассеты
Filament теперь https://localhost:30443/js/...; WAF 18/18 и DDoS 429 на HTTPS.
**Урок:** за TLS-терминатором всегда проверять цепочку X-Forwarded-Proto
до самого приложения (WAF -> nginx -> php-fpm), иначе схема «теряется» и
приложение генерит http-URL из-под https.
## Дополнение: дашборд Service Health (живость сервисов)
Добавлен 4-й дашборд Grafana — UP/DOWN-панели по up{job=...}: Traefik,
Prometheus, Loki, Fluent Bit, Grafana, node-exporter, kubelet/cAdvisor,
API server + готовность подов full-proj (kube_pod_status_ready).
Для этого: включены метрики Traefik (metrics.prometheus.enabled + service
true -> svc traefik-metrics:9100) и добавлены static-джобы Prometheus
(job=traefik/loki/fluent-bit/grafana).

### Инцидент 11: три ошибки при подключении новых таргетов
1. traefik-metrics: чарт traefik по умолчанию НЕ создаёт metrics-сервис
   (metrics.prometheus.service.enabled=false) -> DNS no such host.
2. grafana: target указывал порт 3000, а у сервиса grafana внешний порт 80
   (targetPort 3000) -> context deadline exceeded.
3. grafana /metrics (Grafana 12) отдаётся БЕЗ авторизации — basic_auth в
   scrape не нужен; при этом /api требует пароль, и пароль по умолчанию уже
   не работает (сменён в UI; пароль живёт в PVC, env
   GRAFANA_ADMIN_PASSWORD действует только при первой установке).
**Бонус:** rollout restart grafana завис (новый под Init:CrashLoopBackOff
на chown PVC, пока старый под держит RWO-том) — лечится scale 0->1.
**Урок:** для static-таргетов всегда сверять ПОРТ СЕРВИСА (kubectl get
svc), а не порт контейнера; проверять, что отдаёт /metrics (auth или нет).
## Инцидент 12: Grafana 12 — краш рендера stat-панелей (colorMode)
UI-ошибка: `Error: "background" not found in: fixed,shades,thresholds,...`
на дашборде Service Health. В Grafana 12 у stat-панелей поменялись режимы
цвета: старые `colorMode: "background"/"value"` больше не валидны, а
fieldConfig `color.mode: "background"` удалён.
**Решение:** options.colorMode -> "thresholds" (фон по порогам), ключ
`color` из fieldConfig удалён; то же для k8s-app.json (было "value").
Провайжинер дашбордов подхватывает изменённый ConfigMap без рестарта пода.
**Урок:** при написании дашбордов для Grafana 12 использовать
colorMode=thresholds; после правок JSON — jq empty + проверить в UI.
## Сессия (ночь): DevSecOps — gitleaks + Argo CD

### Что сделано
- **Gitleaks** в CI (джоба secrets, полная история; локально 79 коммитов —
  no leaks found).
- **Argo CD** (GitOps): Application full-proj из ветки main, automated sync
  (selfHeal + prune); секреты вне git (secrets.existingSecret=true, Secret
  рендерится из local-secrets.yaml); образы ghcr с тегом = git SHA; WAF
  зафиксирован по диджесту. Дрейф-демо: ручной scale backend -> 3, Argo CD
  вернул 1 за <60с.

### Инцидент 13: Argo CD при первом синке перезаписал app-secrets
Применённый Application ссылался на чарт из git, где ещё НЕ было условия
existingSecret -> Argo применил секрет с ПУСТЫМИ значениями из values.yaml
git'а -> бэкенд 500, деталки 404.
**Решение:** запушен чарт с existingSecret; Argo синкнул новую ревизию и
prune'нул app-secrets (секрет исчез); восстановлен kubectl apply из
local-secrets.yaml + rollout restart backend -> 200/200.
**Урок:** сначала коммитить чарт, потом применять Application; секреты,
создаваемые чартом по умолчанию, при миграции на GitOps прунятся — быть
готовым пересоздать их внешним путём сразу после синка.

### Инцидент 14 (мелочи Argo CD)
- NodePort 30443 конфликтовал с Traefik HTTPS -> argocd server nodePortHttps
  выставлен 30445.
- refresh API отвечал 415/404 — авто-обновление (poll ~3 мин) работает и без
  ручного refresh.
- Память ноутбука впритык (418Mi свободно): у Argo отключены dex/
  notifications/applicationset.
- helm release full-proj оставлен в кластере как legacy-запись (uninstall
  делать НЕЛЬЗЯ — удалит PVC с данными).
## Сессия (финал DevSecOps): SOPS + ротация секретов

### Что сделано (по ревью, раздел 1)
- **SOPS + age**: .sops.yaml (encrypted_regex ^secrets$), helm/secrets/dev.yaml
  зашифрован и КОММИТИТСЯ; приватный ключ ~/.config/sops/age/keys.txt (вне
  git); deploy.sh: sops -d -> helm template secrets -> kubectl apply, fallback
  local-secrets.yaml; deploy.yml: вместо 10 --set-string — sops -d с
  SOPS_AGE_KEY (один GitHub Secret).
- Шаблон secrets.yaml: required-гарды (APP_KEY/DB_PASSWORD/DB_ROOT_PASSWORD).
- **APP_KEY ротирован** (новый сгенерирован, применён в кластер; сессии
  Filament сброшены — ре-логин).
- **Пароль Argo CD сменён** (случайный, bcrypt только в argocd-secret
  кластера; initial-admin-secret удалён; из git/README/паспорта убран).
  Новый пароль сохранён в ~/.config/sops/argocd-admin-password.txt (chmod 600).
- **Grafana**: adminPassword убран из values/deploy.sh; admin.existingSecret
  = grafana-admin-secret; GRAFANA_ADMIN_PASSWORD теперь обязателен (:?).
- .gitleaks.toml: правило laravel-app-key + allowlist CMS/.env.example
  (исторический ключ ротирован). Локально: 81 коммит — no leaks.
- Баланс: helm-secrets-плагин в Argo CD НЕ ставили (хрупко для проверки) —
  секрет остаётся вне git через existingSecret; ESO — в роадмап SPEC-08.

### Инцидент 15: 502 после ротации APP_KEY (VPN снова)
После рестарта бэкенда всё отдавало 502: WAF не мог резолвить
nginx.full-proj (NXDOMAIN) — VPN снова включился и ломал DNS/conntrack
(kube-dns ClusterIP держал старый DNAT на мёртвый под coredns).
**Решение:** rollout restart coredns + перезапрос; юзер снова выключил VPN.
**Урок:** после перезапуска coredns сбрасывать conntrack
(sudo conntrack -D) либо просто подождать ~30с; VPN-эпизоды уже шаблон.
## Сессия: clean-room — развёртывание с нуля из GitHub

### Что сделано
- Старый стек полностью снесён (5 неймспейсов, helm-релизы, CRD Argo,
  GatewayClass); БД забекаплена (mysqldump).
- Свежий клон github.com/Beasbe/khakaton_MTS -> build-images.sh -> deploy.sh
  (GRAFANA_ADMIN_PASSWORD обязателен) -> Argo CD синкнул приложение из git
  (rev=48d43de, HEAD).
- Верифицировано: приложение https 200, WAF 18/18, Grafana (новый пароль
  работает), Prometheus 15 целей, Argo CD login через initial-admin-secret.
- Демо-данные восстановлены из дампа (3 новости, деталка 200).

### Инцидент 16 (нашёл clean-room): deploy.sh падал на чистом кластере
gen-cert.sh применял TLS-секрет в namespace full-proj ДО его создания —
на старом стенде namespace всегда существовал, поэтому баг не всплывал.
**Решение:** namespace создаётся сразу после проверки зависимостей.
**Урок:** чистый прогон обязателен перед сдачей; скрытое состояние
локального стенда маскирует такие баги.

### Инцидент 17 (нюанс SOPS): приоритет sops-файла в clean-room
deploy.sh взял секреты из зашифрованного helm/secrets/dev.yaml (мой age-ключ
на машине), а НЕ из свежего local-secrets.yaml — ожидаемо по дизайну, но
для проверяющего без ключа sops -d упадёт и сработает fallback на
local-secrets.yaml. Учесть в доке: у судей без ключа всегда fallback.
