# SPEC-06 — WAF (ModSecurity + OWASP CRS)

> Дополнительное улучшение решения (безопасность). Полная спецификация: [`waf/SPEC.md`](../../waf/SPEC.md).

## 0. Мета

| | |
|---|---|
| Статус | ✅ Реализовано и проверено **в обоих контурах**: Docker Compose и Kubernetes |
| Компоненты | ModSecurity 3.0.17, ModSecurity-nginx 1.0.4, OWASP CRS 4.29.0 (образ `owasp/modsecurity-crs:nginx-alpine`) |

## 1. Что реализовано

| ID | Функция | Механизм |
|----|---------|----------|
| FR-WAF-1 | Весь трафик (бэкенд И фронтенд) проходит WAF | единая точка входа: Gateway API → HTTPRoute → `Service waf`; WAF маршрутизирует по path (`map $uri $waf_upstream`): `/api`, `/admin`, `/storage` и т.д. → бэкенд, остальное → фронтенд; внешних портов у приложений нет |
| FR-WAF-2 | OWASP CRS (paranoia 1, блокирующий режим) | env контейнера (`MODSEC_RULE_ENGINE=On`) |
| FR-WAF-3 | Блокировка сканеров/ботнетов по `User-Agent` | правило `1000001` + `scanners-botnets.data` |
| FR-WAF-4 | L7-DDoS защита статики | nginx `limit_req` (30 r/s + burst 60 → HTTP 429) |
| FR-WAF-5 | Audit-лог с ID правил | JSON в stdout (`kubectl logs deploy/waf`) |

В Kubernetes конфигурация задаётся ConfigMap'ами (`helm/templates/waf.yaml`):
`waf-custom-rules`, `waf-scanners-data`, `waf-nginx-template`; правило 1000001
загружается до CRS (`REQUEST-899-...`).

## 2. Верификация (фактические результаты, k8s через Gateway API)

```bash
./waf/tests/run-tests.sh http://localhost:30080
# Summary: 18 passed, 0 failed
#   легитимный трафик: Chrome/Firefox/curl/API -> 200
#   9 сканеров по UA -> 403 (правило 1000001)
#   SQLi/XSS/path traversal/command injection -> 403 (CRS)

python3 waf/tests/ddos_static.py --url http://localhost:30080/favicon.ico
# часть ответов 429 (limit_req)

kubectl logs -n full-proj deploy/waf | grep '"ruleId"'
# {"messages":[{"details":{"ruleId":"1000001",...}}]} — audit-лог JSON
```

## 3. Ограничения / роадмап

1. TLS не настроен (самоподписанный сертификат образа) — для продакшена cert-manager.
2. Пороги (`rate`, `burst`, аномалии) подобраны под демонстрацию; для прода
   нужен профиль реального трафика.
3. В Docker Compose-контуре фронтенд отдаётся напрямую (`:3000`) — вариант A
   (единая точка входа) реализован в Kubernetes-контуре; Compose — локальная разработка.
