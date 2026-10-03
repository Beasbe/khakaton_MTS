# MIGRATION.md — перенос репозитория на новый GitHub

Чек-лист переноса `full_proj` на свежий аккаунт/репозиторий GitHub.
После переноса решение должно оставаться полностью воспроизводимым
(см. [`docs/specs/09-migration.md`](docs/specs/09-migration.md)).

## 1. Новый репозиторий

```bash
# создать пустой репозиторий на GitHub (БЕЗ README/LICENSE/.gitignore),
# затем из локального клона:
git remote set-url origin git@github.com:<NEW_ORG>/<NEW_REPO>.git
# или https://github.com/<NEW_ORG>/<NEW_REPO>.git
git push -u origin main
```

Локальная история уже очищена от секретов (см. SPEC-08) — новый репозиторий
наследует чистую историю.

## 2. Настройки GitHub Actions (новый репозиторий)

`Settings → Secrets and variables → Actions`:

**Secrets** (используются в `.github/workflows/deploy.yml`):

| Secret | Назначение |
|---|---|
| `APP_KEY` | Laravel APP_KEY (`php artisan key:generate --show`) |
| `DB_PASSWORD` | пароль БД приложения |
| `DB_ROOT_PASSWORD` | root-пароль MariaDB |
| `APP_URL` | публичный URL бэкенда |
| `SMTP_HOST` / `SMTP_PORT` / `SMTP_USER` / `SMTP_PASS` / `SMTP_FROM` / `TO_EMAIL` | SMTP для формы контактов |

**Variables** (не секреты):

| Variable | Значение |
|---|---|
| `RUNNER_LABEL` | имя self-hosted runner (по умолчанию `server`) |
| `NEXT_PUBLIC_API_URL` | URL бэкенда, вшиваемый во фронтенд при сборке |

## 3. Self-hosted runner

На сервере (Ubuntu 24.04) с Docker, kubectl и Helm:

```bash
# добавить runner для НОВОГО репозитория:
# GitHub → Settings → Actions → Runners → New self-hosted runner
./config.sh --url https://github.com/<NEW_ORG>/<NEW_REPO> --token <TOKEN>
./run.sh
```

Runner должен иметь доступ к kubeconfig кластера k3s.

## 4. GHCR

В CI образы публикуются автоматически в
`ghcr.io/<org>/<repo-lowercase>/{backend,frontend}` (первый запуск создаст
пакеты; имя репозитория приводится к нижнему регистру — GHCR не принимает
заглавные, `khakaton_MTS` → `khakaton_mts`). Пакеты связаны с публичным
репозиторием — анонимный `docker pull` работает без авторизации (проверено).
В `helm/values.yaml` строка `registry` переопределяется в CI через
`--set registry=ghcr.io/<repo-lowercase>`.

## 5. Что обновить после переноса

- [x] `Ссылка.txt` (архив сдачи) — актуальная ссылка на ветку `main` нового репозитория;
- [x] `docs/specs/01-kubernetes.md` — фактическая версия k3s/Kubernetes стенда Ответ: переделываем под k3s;
- [x] `docs/passport.md` — версия Kubernetes, если изменилась;
- [x] IP/домен стенда в `NEXT_PUBLIC_API_URL` (Variable, не хардкод);
- [x] `CORS_ALLOWED_ORIGINS` (CMS `.env`/Secret) — домены фронтенда нового стенда;
- [x] разовые значения SMTP — как Secrets.

## 6. Проверка после переноса

```bash
git ls-remote origin main                 # новый remote отвечает
# CI (авто при push в main): helm lint -> сборка -> push в GHCR
# CD (вручную): Actions -> CD (deploy) -> Run workflow на self-hosted runner
kubectl get pods -n full-proj             # все Running
curl -s http://<node-ip>:30080/api/news   # 200 + JSON
./waf/tests/run-tests.sh                  # WAF 18/18 (на Compose-контуре)
```

## 7. Заметки

- Фронтенд (`It_project/`) входит в состав репозитория — субмодулей больше нет,
  ничего дополнительно клонировать не нужно.
- Удалены устаревшие `.gitlab-ci.yml` и корневой `deploy.yml` (дубликат workflow).
- На старом репозитории рекомендуется очистить мусорные ссылки
  `refs/remotes/origin/*` (см. SPEC-09) — сделано при миграции.
