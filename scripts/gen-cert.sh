#!/usr/bin/env bash
# =============================================================================
#  Самоподписанный TLS-сертификат для Gateway API (listener https :443).
#  Кладёт Secret tls full-proj-tls в namespace full-proj (идемпотентно).
#  Вызывается из deploy.sh; можно звать вручную с дополнительными IP:
#    ./scripts/gen-cert.sh [IP1 [IP2 ...]]
#  SAN всегда включает localhost, 127.0.0.1 и стабильный IP ноды 192.168.200.1
#  (dummy-интерфейс k3sip0, см. SPEC-01, Примечание 3).
#  Браузер будет ругаться на недоверенный CA — это ожидаемо для
#  самоподписанного сертификата (см. README, раздел HTTPS).
# =============================================================================
set -euo pipefail

NAMESPACE="${NAMESPACE:-full-proj}"
SECRET_NAME="${SECRET_NAME:-full-proj-tls}"
DAYS="${CERT_DAYS:-825}"

ALT="DNS:localhost,IP:127.0.0.1,IP:192.168.200.1"
for ip in "$@"; do
  ALT="${ALT},IP:${ip}"
done

TMP_KEY="$(mktemp)"
TMP_CRT="$(mktemp)"
trap 'rm -f "$TMP_KEY" "$TMP_CRT"' EXIT

openssl req -x509 -nodes -newkey rsa:2048 -days "${DAYS}" \
  -keyout "${TMP_KEY}" -out "${TMP_CRT}" \
  -subj "/CN=full-proj" \
  -addext "subjectAltName=${ALT}" >/dev/null 2>&1

kubectl create secret tls "${SECRET_NAME}" -n "${NAMESPACE}" \
  --cert="${TMP_CRT}" --key="${TMP_KEY}" \
  --dry-run=client -o yaml | kubectl apply -f - >/dev/null

echo "==> TLS-секрет ${NAMESPACE}/${SECRET_NAME} обновлён (SAN: ${ALT})"
