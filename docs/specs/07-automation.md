# SPEC-07 — Автоматизация развёртывания

> Источник требований: кейс «MTC ENGINEER HACK», разделы 6 «Поддержка ОС» и 7 «Автоматизация развёртывания».

## 0. Мета

| | |
|---|---|
| Статус | ✅ Реализовано (Compose + Kubernetes), идемпотентность проверена |
| ОС | Ubuntu 24.04.5 LTS (стенд); Docker-путь — любая ОС с Docker |
| Инструменты | shell (`scripts/build-images.sh`, `scripts/deploy.sh`), Docker Compose, Helm, GitHub Actions (CI — авто на push/PR; CD — вручную) |

## 1. Требования

| ID | Требование | Статус |
|----|-----------|--------|
| FR-AUT-1 | Развёртывание воспроизводимо по инструкции, без ручного создания ресурсов | ✅ |
| FR-AUT-2 | Повторный запуск идемпотентен | ✅ проверено (повторный `deploy.sh` → «has been upgraded», состояние не ломается) |
| FR-AUT-3 | Минимум понятных команд | ✅ `./scripts/build-images.sh` + `./scripts/deploy.sh` |
| FR-AUT-4 | Поддержка Ubuntu 24.04 | ✅ развёрнуто и проверено на Ubuntu 24.04.5 |
| FR-AUT-5 | CI/CD (доп. улучшение) | ✅ CI: `.github/workflows/ci.yml` (helm lint + сборка + push в GHCR, авто на push/PR). CD: `.github/workflows/deploy.yml` (workflow_dispatch, self-hosted runner) — запускает принимающая сторона |

## 2. Реализация

### 2.1. Локальная разработка (Docker Compose)

`./setup.sh` / `setup.ps1`: проверка зависимостей → `.env` из примеров →
`docker compose up -d --build` → composer → `key:generate` → миграции → админ.

### 2.2. Kubernetes (основной контур)

```bash
./scripts/build-images.sh     # backend/frontend/waf -> локальный registry localhost:5000
./scripts/deploy.sh           # весь стек (см. ниже)
```

`deploy.sh` выполняет 7 идемпотентных шагов:
1. Gateway API CRD v1.5.1 + workaround CoreDNS для k3s v1.36.x;
2. Traefik v3 (Gateway API, NodePort 30080 HTTP + 30443 HTTPS);
3. самоподписанный TLS-сертификат (`scripts/gen-cert.sh`) + Secret `app-secrets`
   (рендерится шаблоном чарта из `local-secrets.yaml` — секреты вне git);
4. Prometheus (+node-exporter, +kube-state-metrics из чарта);
5. Grafana (дашборды из ConfigMap, Prometheus+Loki datasources, NodePort 30300);
6. Loki + Fluent Bit;
7. **Argo CD** (GitOps, NodePort 30444) + Application `full-proj` — приложение
   разворачивается ИЗ репозитория (ветка main, чарт `helm/`): automated sync
   (selfHeal + prune), образы из ghcr.io с тегом = git SHA.

Все чарты тянутся как OCI-артефакты из ghcr.io (без `helm repo add`).

### 2.3. CI/CD

- **CI (`.github/workflows/ci.yml`)** — автоматически на push в `main` и на PR
  (GitHub-hosted runner): `helm lint helm` → сборка backend/frontend
  (`docker/build-push-action`, buildkit-кеш) → push в GHCR с тегами
  `:latest` и `:${{ github.sha }}`. В PR образы собираются без push.
  `NEXT_PUBLIC_API_URL` берётся из Variable репозитория (fallback
  `http://localhost:30080`).
- **CD (`.github/workflows/deploy.yml`)** — запускается вручную
  (`workflow_dispatch`): требует self-hosted runner с Docker/kubectl/helm и
  доступом к кластеру; выполняет `helm upgrade --install` с секретами из
  GitHub Actions secrets, ждёт rollouts, при ошибке выводит диагностику.
  Развёртывание на стенде выполняет принимающая сторона (см. MIGRATION.md).
- **GitOps (Argo CD)** — на стенде приложение управляется не CD-воркфлоу, а
  Argo CD: источник истины — репозиторий (`argocd/application.yaml`), любой
  ручной дрейф кластера откатывается автоматически (selfHeal).

## 3. Верификация

```bash
./scripts/deploy.sh      # повторный запуск: "has been upgraded", exit 0
kubectl get pods -A      # все Running
curl -s http://localhost:30080/api/news | head -c 120   # 200 + JSON
```

## 4. Ограничения / роадмап

1. Smoke-тест (curl после деплоя) добавить в CI/CD.
2. `kubeconform` для строгой валидации манифестов (сейчас — `helm lint`).
3. Интерактивное создание админа в `setup.sh` → неинтерактивный режим через env.
4. kubeadm-вариант установки кластера (приоритет кейса) — опциональный путь.
