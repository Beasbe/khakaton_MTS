# SPEC-02 — Демонстрационное веб-приложение

> Источник требований: кейс «MTC ENGINEER HACK», раздел 2 «Демонстрационное веб-приложение».

## 0. Мета

| | |
|---|---|
| Статус | ✅ Реализовано |
| Приложение | Laravel 10 (PHP 8.1+) + Filament 3 CMS + MariaDB 10.11 + Next.js 16 (React 19) |
| Образы | публично собираются из репозитория (`CMS/Dockerfile`, `It_project/dockerfile`) и публикуются в GHCR |

## 1. Требования

| ID | Требование | Статус |
|----|-----------|--------|
| FR-APP-1 | Приложение принимает HTTP-запросы | ✅ nginx + php-fpm (Laravel), Next.js |
| FR-APP-2 | Возвращает однозначно проверяемый ответ | ✅ `GET /api/news`, `/api/projects` → JSON; фронтенд → HTML |
| FR-APP-3 | Формирует access-логи HTTP-запросов для последующего сбора | ✅ nginx access-лог → stdout контейнера |
| FR-APP-4 | Позволяет однозначно проверить успешность запроса | ✅ HTTP-коды и тело ответа |
| FR-APP-5 | Образ публично доступен ИЛИ собирается из материалов репозитория | ✅ оба пути |

## 2. Реализация

- **Бэкенд**: Laravel 10; API-маршруты `CMS/routes/api.php` (`/api/news`, `/api/projects`,
  контроллеры `CMS/app/Http/Controllers/Api/*`); админ-панель Filament `/admin`;
  отдача статики и проксирование PHP — nginx (`CMS/docker/nginx/default.conf`).
- **Фронтенд**: Next.js 16 (`It_project/`), SSR-страницы + клиентские выборки
  `NEXT_PUBLIC_API_URL` (вшивается при сборке образа build-arg'ом).
- **БД**: MariaDB 10.11 (Compose) / `k8s/mysql.yaml` (K8s).
- **Логи**: nginx пишет access/error-логи в stdout/stderr контейнеров (`webserver`, `waf`,
  `frontend`), поэтому они доступны через `docker logs` / `kubectl logs` и готовы
  к сбору Fluentd/Filebeat (SPEC-05).

## 3. Верификация

```bash
# Compose
curl -s http://localhost:8080/api/news | head -c 300     # 200 + JSON
curl -s -o /dev/null -w '%{http_code}\n' http://localhost:8080/   # 200
docker compose logs --tail=5 webserver                    # access-логи

# Kubernetes
curl -s http://<node-ip>:30080/api/news | head -c 300     # 200 + JSON
kubectl logs -n full-proj deploy/nginx --tail=5           # access-логи
```

## 4. Ограничения

- Frontend-контейнер Next.js использует standalone-сборку; доступ к нему —
  только через Gateway API → WAF (вариант A), отдельного внешнего порта нет.
- В K8s-контуре порт `backend` не публикуется наружу — весь трафик идёт через `nginx`.
