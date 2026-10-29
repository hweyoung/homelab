# monitoring

kube-prometheus-stack chart로 Prometheus Operator, Prometheus, Grafana, kube-state-metrics,
node-exporter를 `monitoring` Namespace에 설치한다. 애플리케이션 로그는 Alloy가 수집해 Loki에
저장한다. Alertmanager는 warning/critical 알림을 Discord로 보낸다.

| Application | wave | 경로 | 리소스 |
| --- | --- | --- | --- |
| platform-monitoring-secrets | -8 | `external-secrets/` | SA, SecretStore, ExternalSecret 2개 |
| platform-kube-prometheus-stack | -7 | `values.yaml` | CRD, operator, Prometheus, Grafana, exporter |
| platform-grafana-route | -6 | `exposure/` | `grafana.okbear.dev` HTTPRoute |
| platform-loki | -6 | `loki/values.yaml` | Loki SingleBinary StatefulSet |
| platform-alloy | -5 | `alloy/values.yaml` | Pod 로그 수집 DaemonSet |
| platform-monitoring-rules | -4 | `rules/` | 홈랩 플랫폼 PrometheusRule |
| platform-grafana-dashboards | -4 | `dashboards/` | Grafana 대시보드 ConfigMap ([README](dashboards/README.md)) |

Namespace는 namespaces Application이 소유하므로 세 Application 모두
`platform-existing-namespace` 정책을 사용한다. chart 버전은 root-app `platformVersions`의
`kube-prometheus-stack.activeVersion`으로 변경한다. chart는 control plane scrape용 Service를
`kube-system`에 만들기 때문에 platform AppProject가 `kube-system` destination을 허용한다.

## 수집 범위

- Prometheus는 release label과 관계없이 모든 Namespace의 ServiceMonitor, PodMonitor,
  PrometheusRule을 선택한다.
- 보존 기간은 15일/18GB, 저장소는 `local-path` 20Gi PVC다. Grafana도 5Gi PVC를 쓰므로
  `Recreate` 전략으로 배포한다. Prometheus PVC는 prod Worker에, Grafana PVC는
  prod/dev taint를 모두 허용해 최초 배치된 Worker에 결합된다.
- Kubespray 기본 구성에서 etcd(host 서비스, mTLS)와 kube-proxy(127.0.0.1 bind) metrics는
  수집할 수 없으므로 비활성화했다. controller-manager와 scheduler target은 sync 후 `up`
  상태를 확인하고, bind 주소 때문에 down이면 Kubespray 변수로 조정하거나 비활성화한다.

## 로그 수집

- Alloy DaemonSet은 모든 NoSchedule taint를 허용해 control plane, prod, dev 노드에 배치된다.
  각 Pod는 자기 노드의 `/var/log/pods`만 읽고 `namespace`, `pod`, `container`, `app`, `node`
  label을 붙여 `platform-loki.monitoring:3100`으로 전송한다.
- Loki는 SingleBinary 1개 Pod가 prod Worker의 `local-path` 30Gi PVC에 저장하며 보존 기간은
  14일이다. PVC는 Application 삭제나 replica 조정에도 유지한다. memcached cache, gateway,
  canary는 사용하지 않는다.
- Grafana에는 `Loki` 데이터소스가 추가된다. Explore에서 `{namespace="api-common-dev"}`처럼
  조회한다.

## Alertmanager와 Discord

- route는 `namespace`, `alertname`으로 묶고 기본 receiver를 Discord로 둔다. critical은 1시간,
  나머지는 12시간마다 다시 알린다.
- 항상 firing인 `Watchdog`, inhibit 전용 `InfoInhibitor`, `severity=info` alert는 `null`
  receiver로 보낸다. chart 기본 inhibit rule(critical이 같은 alert의 warning/info를 억제)은 유지한다.
- Discord webhook URL은 ExternalSecret `alertmanager-discord`가 만든 Secret을
  `alertmanagerSpec.secrets`로 mount하고 `webhook_url_file`로 읽는다. 값은 Git과 렌더된 설정
  어디에도 남지 않는다.
- Alertmanager는 prod Worker에 고정하고 silence 기록을 `local-path` 2Gi PVC에 둔다.

## 수집 대상 추가

다른 Application에서 metric 옵션을 켜 monitoring Prometheus가 수집한다.

| 대상 | 리소스 | 선언 위치 |
| --- | --- | --- |
| Traefik | metrics Service + ServiceMonitor | `platform/traefik/values.yaml` |
| cert-manager | ServiceMonitor | `platform/cert-manager/values.yaml` |
| External Secrets | ServiceMonitor | `platform/external-secrets/values.yaml` |
| CNPG operator | PodMonitor | `platform/cloudnative-pg/values.yaml` |
| PostgreSQL Cluster | PodMonitor `postgres` | `databases/postgres/base/podmonitor.yaml` |
| OpenBao | 내부 전용 listener `:8210` + ServiceMonitor | `platform/openbao/values.yaml` |
| Garage | admin 포트 `:3903` + ServiceMonitor | `platform/garage/` |
| cloudflared | PodMonitor (`:2000`) | `platform/cloudflared/podmonitor.yaml` |

OpenBao는 공개 HTTPRoute가 UI Service의 8200만 가리키므로, 인증 없는 `/v1/sys/metrics`는 별도
listener `:8210`에서만 허용한다. 차트가 8202를 replication 포트로 쓰기 때문에 8210을 사용한다.
`updateStrategyType: OnDelete`라 설정 반영에는 Pod 삭제와 수동 unseal이 필요하다. ServiceMonitor는
`openbao-active` Service만 고르므로 sealed 상태에서는 target이 사라진다.

cert-manager와 ESO 지표는 대상 리소스의 `namespace` label을 가지므로 두 ServiceMonitor에
`honorLabels: true`를 둬서 target namespace로 덮이지 않게 한다.

이 리소스는 Prometheus Operator CRD가 있어야 적용된다. 새 클러스터 bootstrap에서는
kube-prometheus-stack(wave -7)보다 앞 wave의 Application이 CRD 설치 전까지 sync 실패 후
재시도할 수 있다. ESO chart는 CRD가 없으면 ServiceMonitor 렌더를 건너뛴다.

## 홈랩 알림 rule

`rules/homelab-platform-rules.yaml`은 chart 기본 rule에 없는 OpenBao, Garage, Cloudflare Tunnel,
Traefik 5xx, 인증서, ExternalSecret, PostgreSQL 알림을 둔다. OpenBao ServiceMonitor는 active
Service만 수집해 sealed 상태에서는 지표가 사라지므로 `OpenBaoSealed`는 `vault_core_unsealed`가
없을 때도 firing한다.

## Grafana admin Secret

ExternalSecret `grafana-admin`이 OpenBao KV v2에서 같은 이름의 Secret을 만든다. Grafana는
`admin.existingSecret`으로 이 Secret만 참조하고 chart가 admin Secret을 생성하지 않는다.

| Kubernetes Secret 키 | OpenBao 엔진 내부 경로 | 원본 키 |
| --- | --- | --- |
| admin-user | platform/monitoring/grafana | admin-user |
| admin-password | platform/monitoring/grafana | admin-password |

ExternalSecret `alertmanager-discord`는 Alertmanager용 Secret을 만든다.

| Kubernetes Secret 키 | OpenBao 엔진 내부 경로 | 원본 키 |
| --- | --- | --- |
| webhook-url | platform/monitoring/alertmanager | discord-webhook-url |

OpenBao에는 sync 전에 값, Policy, Kubernetes Auth Role을 준비한다. Role은 SA
`eso-monitoring`과 Namespace `monitoring`에 바인딩하고 audience는 `openbao`로 맞춘다.

```bash
bao kv put secret/platform/monitoring/grafana admin-user=admin admin-password=-
bao kv put secret/platform/monitoring/alertmanager discord-webhook-url=-

bao policy write monitoring - <<'EOF'
path "secret/data/platform/monitoring/*" {
  capabilities = ["read"]
}
EOF

bao write auth/kubernetes/role/monitoring \
  bound_service_account_names=eso-monitoring \
  bound_service_account_namespaces=monitoring \
  audience=openbao \
  policies=monitoring \
  ttl=1h
```

Grafana는 admin 값을 최초 DB 생성 시에만 반영한다. PVC가 이미 있는 상태에서 값을 바꾸면
`grafana cli admin reset-admin-password`로 맞추거나 Pod를 재시작한 뒤 로그인을 확인한다.

## 검증

```bash
kustomize build gitops/platform/monitoring/external-secrets
kustomize build gitops/platform/monitoring/exposure
helm template root-app gitops/clusters/homelab/root-app
```

Argo CD sync 후:

```bash
kubectl -n monitoring wait --for=condition=Ready secretstore/openbao-monitoring --timeout=120s
kubectl -n monitoring wait --for=condition=Ready externalsecret/grafana-admin --timeout=120s
kubectl -n monitoring wait --for=condition=Ready externalsecret/alertmanager-discord --timeout=120s
kubectl -n monitoring get alertmanager,pod -l app.kubernetes.io/name=alertmanager
kubectl -n monitoring get pod,pvc
kubectl -n monitoring get prometheus,servicemonitor
kubectl -n monitoring get httproute grafana-route
kubectl -n monitoring get statefulset,pvc -l app.kubernetes.io/name=loki
kubectl -n monitoring rollout status daemonset/platform-alloy
kubectl -n monitoring port-forward svc/kube-prometheus-stack-prometheus 9090
```

Prometheus UI의 Status → Targets에서 down target을 확인하고, Grafana는
`https://grafana.okbear.dev`에서 로그인과 기본 Kubernetes dashboard를 확인한다.
