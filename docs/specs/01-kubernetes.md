# SPEC-01 — Kubernetes-окружение

> Источник требований: кейс «MTC ENGINEER HACK», раздел 1 «Kubernetes-окружение».
> Подход: spec-driven development (требования → приёмка → реализация → верификация).

## 0. Мета

| | |
|---|---|
| Статус | ✅ Реализовано и проверено локально |
| Кластер | **k3s v1.36.5+k3s1 (Kubernetes v1.36.5)**, containerd 2.3.4, CNI flannel |
| ОС стенда | Ubuntu 24.04.5 LTS |
| Способ развёртывания | Helm-чарт `helm/` + инфраструктурные чарты `infra/` (одна команда: `./scripts/deploy.sh`) |
| Зависит от коммерческих сервисов | нет (все чарты — OCI из ghcr.io, образы собираются локально или в GHCR) |

## 1. Требования

| ID | Требование | Статус |
|----|-----------|--------|
| FR-K8S-1 | Kubernetes-кластер для развёртывания решения | ✅ k3s |
| FR-K8S-2 | Все ресурсы описаны как код, без ручной настройки | ✅ Helm-чарты + `scripts/deploy.sh` |
| FR-K8S-3 | В README указаны: версия K8s, способ создания кластера, ОС | ✅ см. [README](../../readme.md) |
| FR-K8S-4 | Решение не зависит от инфраструктуры участника и коммерческих сервисов | ✅ |
| NFR-K8S-1 | Воспроизводимость экспертами по материалам репозитория | ✅ (см. верификацию) |

## 2. Реализация

### 2.1. Создание кластера (Ubuntu 24.04)

```bash
# k3s без встроенного traefik v2 (ставим Traefik v3 с Gateway API отдельно)
curl -sfL https://get.k3s.io | sh -s - --disable traefik --disable metrics-server
sudo cat /etc/rancher/k3s/k3s.yaml > ~/.kube/config && chmod 600 ~/.kube/config
kubectl get nodes   # Ready
```

> **Примечание 1 (k3s v1.36.x).** CoreDNS может стартовать без env
> `KUBERNETES_SERVICE_HOST/PORT`, из-за чего DNS кластера не работает
> (NXDOMAIN для всех `*.svc.cluster.local`). `scripts/deploy.sh` автоматически
> добавляет эти переменные в deployment `coredns` (идемпотентный patch).
>
> **Примечание 2 (VPN).** Если на машине включён VPN с policy-routing
> (перехват порта 53 или подсети сервисов k3s `10.43.0.0/16`), DNS-запросы
> из подов уходят в туннель и отвечают NXDOMAIN. Для локального стенда VPN
> нужно отключить (проверено на реальном стенде).
>
> **Примечание 3 (ноутбук с нестабильным Wi-Fi/DHCP).** Если адрес Wi-Fi
> меняется между переподключениями (кампусные сети), k3s регистрирует
> протухший `INTERNAL-IP`: kube-proxy DNAT'ит `kubernetes`-сервис на
> исчезнувший IP ноды, мониторинг падает (`no route to host` к `10.43.0.1`,
> liveness node-exporter на старом IP). **Решение:** привязать ноду к
> стабильному локальному адресу — dummy-интерфейсу через NetworkManager —
> и передать его в k3s как `--node-ip` (проверено на стенде):
>
> ```bash
> nmcli con add type dummy con-name k3sip0 ifname k3sip0 \
>   ipv4.addresses 192.168.200.1/32 ipv4.method manual connection.autoconnect yes
> sudo sed -i "s|'metrics-server' \\\\$|'metrics-server' '--node-ip' '192.168.200.1' \\\\|" \
>   /etc/systemd/system/k3s.service
> sudo systemctl daemon-reload && sudo systemctl restart k3s
> ```
>
> После этого `restart k3s` при смене сети НЕ требуется: доступ к приложению
> остаётся на всех интерфейсах (`localhost:30080`, Wi-Fi IP для других
> устройств — NodePort слушает `0.0.0.0`).

### 2.2. Развёртывание решения

```bash
./scripts/build-images.sh   # собрать и залить образы в локальный registry localhost:5000
./scripts/deploy.sh         # CRD Gateway API -> Traefik -> приложение+WAF -> Prometheus -> Loki+Fluent Bit
```

Состав (все компоненты — Helm, повторный запуск идемпотентен):

| Компонент | Ресурс | Источник |
|---|---|---|
| Gateway API CRD | стандартный канал **v1.5.1** | `kubernetes-sigs/gateway-api` |
| Traefik v3.7.13 | `traefik/traefik` (GatewayClass `traefik`) | OCI `ghcr.io/traefik/helm/traefik` |
| Приложение + WAF + Gateway/HTTPRoute | чарт `helm/` (release `full-proj`) | репозиторий |
| Prometheus v3.15 + node-exporter + kube-state-metrics | release `prometheus` | OCI `ghcr.io/prometheus-community/charts/prometheus` |
| Loki 3.6 + Fluent Bit 5.1.3 | releases `loki`, `fluent-bit` | OCI `ghcr.io/grafana/helm-charts/loki`, `ghcr.io/fluent/helm-charts/fluent-bit` |

## 3. Верификация

```bash
kubectl get nodes                       # Ready, v1.36.5+k3s1
kubectl get pods -A                     # все Running (full-proj, monitoring, logging, traefik)
kubectl get gateway -n full-proj        # PROGRAMMED: True, Address: <node-ip>
./scripts/deploy.sh                     # повторный запуск -> "has been upgraded", без ошибок
```

## 4. Известные ограничения / роадмап

1. kubeadm — приоритетный вариант кейса; решение валидировано на k3s (допустимый вариант).
   Для переноса на kubeadm достаточно переустановить Gateway API/Traefik и применить чарт.
2. Raw-манифесты `k8s/` удалены — единственный источник истины Helm-чарт `helm/`.
3. Один узел (control-plane) — для HA нужно ≥3 узла + внешний datastore (роадмап).
