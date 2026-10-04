# SPEC-08 — Безопасность и управление секретами

> Источник требований: кейс «MTC ENGINEER HACK», раздел «Требования к безопасности».

## 0. Мета

| | |
|---|---|
| Статус | ✅ Реализовано (после чистки репозитория) |

## 1. Требования

| ID | Требование | Статус |
|----|-----------|--------|
| FR-SEC-1 | В репозитории нет реальных паролей, API-токенов, приватных SSH-ключей, персональных данных | ✅ |
| FR-SEC-2 | Секреты передаются через переменные окружения / Secret / шаблон конфигурации | ✅ |

## 2. Реализация

| Контур | Механизм передачи секретов |
|---|---|
| Docker Compose | переменные окружения из `.env` (см. [`.env.example`](../../.env.example)); в репозитории — только примеры |
| Kubernetes | Secret `app-secrets` — создаётся ВНЕ git: deploy.sh расшифровывает SOPS-файл `helm/secrets/dev.yaml` (age-ключ: локально `~/.config/sops/age/keys.txt`, в CI — Secret `SOPS_AGE_KEY`) либо берёт gitignored `local-secrets.yaml`; при GitOps чарт ставит `secrets.existingSecret=true` и Secret не трогает; в шаблоне — `required`-гарды (`APP_KEY`, `DB_PASSWORD`, `DB_ROOT_PASSWORD`), в `values.yaml` — пустые |
| CI/CD | GitHub Actions secrets (`APP_KEY`, `DB_PASSWORD`, `SMTP_*`, …) — никогда не в файлах |
| Laravel | `APP_KEY` генерируется при установке (`php artisan key:generate`), в `.env.example` — пустой |

### DevSecOps-контур

| Инструмент | Что делает | Где |
|---|---|---|
| **SOPS + age** | секреты в git только зашифрованными (`helm/secrets/dev.yaml`, правила `.sops.yaml`); deploy.sh/CD расшифровывают одним age-ключом; пароли Argo CD/Grafana в git не хранятся (генерируются в кластере / задаются env) | `.sops.yaml`, `helm/secrets/`, `scripts/deploy.sh` |
| **Gitleaks** | сканирует секреты во ВСЕЙ git-истории (джоба `secrets` в CI, блокирует build; локально: `gitleaks detect`); добавлено правило `laravel-app-key` (`.gitleaks.toml`) | `.github/workflows/ci.yml` |
| **Argo CD** (GitOps) | кластер непрерывно сверяется с репозиторием: `selfHeal` откатывает любые ручные изменения в подах/деплойментах к состоянию из git, `prune` удаляет лишнее; дрейф виден в UI. Проверено: ручной `scale` backend до 3 реплик — Argo CD вернул 1 (как в чарте) | `infra/argocd/values.yaml`, `argocd/application.yaml` |
| Пиннинг диджестов | WAF-образ зафиксирован по `@sha256:...` в `helm/values.yaml` (воспроизводимость, защита от подмены floating-тегов); образы приложения тегируются git SHA в CI и привязываются к коммиту в `argocd/application.yaml` | `helm/values.yaml` |

### Инциденты и их устранение (2026-10-02)

| Что было | Где | Устранение |
|---|---|---|
| SMTP-пароль и SSH-пароль сервера | `It_project/env.local` (трекался) | файл удалён, **история переписана** (filter-branch). **Пароли ротированы 2026-10-02** |
| Реальный `APP_KEY` Laravel | `CMS/.env.example` (трекался) | заменён на пустой; **ключ ротирован 2026-10-04** (новый в sops/local-secrets, сессии сброшены) |
| Пароль Argo CD `argocd123` (+bcrypt в values) | README/паспорт/коммит/`infra/argocd/values.yaml` | удалён из git, **пароль сменён 2026-10-04** (генерируется в кластере, хранение — только в `argocd-secret`) |
| Пароль Grafana `admin`/`admin` | `infra/grafana/values.yaml`, deploy.sh | убран из git: `admin.existingSecret` + обязательный `GRAFANA_ADMIN_PASSWORD` |
| Хардкод кредов БД в Compose | `docker-compose.yml` | вынесены в переменные окружения |
| Хардкод IP стенда | CI, CORS, Compose | параметризован (см. SPEC-09) |

## 3. Верификация

```bash
# 1. gitleaks: во всей истории нет утёкших секретов (CI: джоба secrets)
gitleaks detect --source .                      # "no leaks found"

# 2. SOPS: секреты в git только зашифрованы
sops -d helm/secrets/dev.yaml >/dev/null && echo "расшифровывается (ключ на месте)"

# 3. в git нет паролей Argo CD / Grafana
! grep -rInE 'argocd123|adminPassword: admin' --exclude-dir=.git .

# 4. утёкшие в прошлом значения (после ротации) — проверить паттерны вручную
git log --all --oneline -S 'REDACTED_SMTP_PASS'        # пусто
```

## 4. Роадмап

1. Управление секретами в кластере: **sealed-secrets** или **external-secrets** вместо
   передачи через CI-переменные (сейчас секреты вне git — `local-secrets.yaml`/CI-secrets).
2. NetworkPolicy: разрешить трафик только `nginx → backend → mysql`, `waf → nginx`.
3. TLS для всех внешних эндпоинтов (cert-manager вместо самоподписанного).
