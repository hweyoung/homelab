# monitoring/dashboards

홈랩 Grafana 대시보드를 인프라 → 클러스터 → 애플리케이션 계층으로 나눠 ConfigMap으로 배포한다.
Application `platform-grafana-dashboards`(wave -4)가 배포하고, kube-prometheus-stack Grafana sidecar가
`grafana_dashboard: "1"` label을 보고 등록하며 `grafana_folder` annotation으로 폴더를 나눈다.

## 구성

| Grafana 폴더 | 대시보드 (uid) | 데이터 | 보는 시점 |
| --- | --- | --- | --- |
| 00 Overview | Homelab Overview (`homelab-overview`) | 전 계층 요약 | 매일 첫 화면, 알림을 받았을 때 |
| 01 Infrastructure | 인프라 · 노드 (`homelab-infra-nodes`) | node-exporter | 노드 자원이 의심될 때 |
| 02 Cluster | 클러스터 · Kubernetes (`homelab-k8s-cluster`) | kube-state-metrics, cAdvisor, control plane | Pod 장애, 리소스 부족 |
| 02 Cluster | 클러스터 · 플랫폼 서비스 (`homelab-platform-services`) | OpenBao, Garage, CNPG, ESO | Secret/스토리지/DB 문제 |
| 02 Cluster | 클러스터 · Ingress · Edge (`homelab-ingress-edge`) | Traefik, cloudflared, cert-manager | 외부 접속 문제 |
| 03 Application | 애플리케이션 (`homelab-application`) | Traefik, cAdvisor, 앱 지표, Loki | 서비스 하나를 깊게 볼 때 |
| 99 Kubernetes (chart 기본) | kube-prometheus-stack 기본 대시보드 | - | 세부 참고용 |

모든 대시보드에 공통으로 적용한 것:

- 위에서 아래로 **요약(Stat) → 추세(Time series) → 상세(Table) → 로그** 순서. 상세 행은 접어 두었다.
- Overview의 Stat/Table을 클릭하면 해당 상세 대시보드로 이동한다(Data link, 시간 범위 유지).
- 오른쪽 위 `Homelab 대시보드` 드롭다운으로 `homelab` tag 대시보드 사이를 이동한다.
- Shared crosshair: 한 그래프의 시점이 모든 그래프에 같이 표시된다.
- 데이터소스는 변수(`datasource`, `loki`)로 받는다. 기본값은 chart가 만든 uid `prometheus`, `loki`다.
- 수집되지 않는 지표는 "No data" 대신 `수집 안 됨`으로 표시해 설정 누락과 정상 0을 구분한다.

## 대시보드별 메모

- **인프라**: node-exporter의 `instance`(IP:9100)를 `node_uname_info`와 join해 `k8s-master`, `k8s-worker-prod`,
  `k8s-worker-dev` 이름으로 표시한다. local-path PVC가 모두 노드 루트 디스크(`/opt/local-path-provisioner`)에
  있으므로 루트 디스크 사용률과 "24시간 뒤 예상 여유 공간"이 곧 Prometheus/Loki/OpenBao/Garage/PostgreSQL의 여유다.
- **클러스터 · Kubernetes**: local-path는 `kubelet_volume_stats_*`가 나오지 않아 PVC 실사용량 패널 대신 요청 용량과
  노드 디스크를 함께 보여 준다. etcd/kube-proxy는 values.yaml에서 수집을 끈 상태다.
- **플랫폼 서비스**: OpenBao(`:8210`), Garage(`:3903`) 지표는 각 컴포넌트 옆의 ServiceMonitor가 수집한다. OpenBao는 sealed 상태에서 target이 사라져 `수집 안 됨`으로 보인다.
- **Ingress · Edge**: Traefik Gateway provider의 service 이름은 `<namespace>-<service>-<port>` 형태라
  애플리케이션 대시보드는 service 이름에 namespace가 포함된 것을 골라 쓴다.
- **애플리케이션**: Namespace를 하나 고르면 Traefik 기준 RED, Pod 리소스, 로그를 바로 볼 수 있다.
  런타임(JVM) 행은 앱이 지표를 노출해야 채워진다.
  - Spring Boot(api-common): `spring-boot-starter-actuator`, `micrometer-registry-prometheus` 추가,
    `management.endpoints.web.exposure.include=health,prometheus` 설정 후 ServiceMonitor 추가
  - Jira Data Center: Helm `monitoring.exposeJmxMetrics: true`, `monitoring.serviceMonitor.create: true`
  - 패널은 Micrometer 이름(`jvm_memory_used_bytes`, `hikaricp_*`, `tomcat_threads_*`)과 JMX exporter 이름
    (`jvm_memory_bytes_used`, `Catalina_*`, `com_atlassian_jira_*`)을 모두 조회한다.

## 관리 방식

Git을 대시보드의 원본으로 둔다. 클러스터나 Grafana PVC를 다시 만들어도 같은 화면이 나오고,
Overview Data link와 alert `dashboard` annotation이 참조하는 uid를 함께 관리할 수 있기 때문이다.

| 대상 | 관리 위치 |
| --- | --- |
| `00 Overview` ~ `03 Application` 등 계속 쓰는 대시보드 | Git (`json/<폴더>/`) |
| 장애 분석, 패널 실험, 임시 쿼리 | Grafana UI의 `Sandbox` 폴더 (Git 관리 밖) |
| kube-prometheus-stack 기본 대시보드 | chart (수정하지 않음) |

kube-prometheus-stack의 sidecar provider는 `allowUiUpdates: false`다. Git에서 온 대시보드는 UI에서
편집은 되지만 저장은 막히고, Grafana는 JSON 복사만 제공한다. UI 변경이 Git 내용과 섞이지 않도록 이
설정은 유지한다. `Sandbox` 폴더의 대시보드는 Grafana PVC(`grafana.db`)에만 있고 백업되지 않는다.

## 수정 방법

1. 새 대시보드는 `Sandbox` 폴더에서 만들고, 기존 대시보드는 UI에서 바로 편집한다.
2. Dashboard settings → JSON Model을 복사하거나 Export → Export as JSON으로 받는다.
   `Export for sharing externally`는 **끈다**(데이터소스가 `${DS_...}` 입력값으로 바뀐다).
3. 최상위 `id`, `version`, `iteration`은 지운다. export마다 값이 바뀌어 diff만 키운다.
4. `json/<폴더>/` 아래 같은 파일을 덮어쓴다. 새 대시보드는 uid를 정하고 `kustomization.yaml`의
   해당 ConfigMap `files`에 추가한다.
5. commit하면 sync 후 sidecar가 30초 안에 다시 로딩한다. `Sandbox`에 만든 원본은 지운다.

대시보드 uid는 Data link와 alert annotation이 참조하므로 한 번 정하면 바꾸지 않는다. Grafana chart
버전을 올리면 export 결과의 `schemaVersion`이 바뀔 수 있으므로, 버전 업그레이드와 대시보드 수정은
commit을 나눈다.

Overview를 홈 화면으로 쓰려면 Grafana의 Administration → Default preferences → Home Dashboard에서
`00 Overview/Homelab Overview`를 고른다(Grafana PVC에 저장된다).

## 검증

```bash
kustomize build gitops/platform/monitoring/dashboards | grep -E '^  name:|grafana_folder'

# sync 후
kubectl -n monitoring get configmap -l grafana_dashboard=1
kubectl -n monitoring logs deploy/platform-kube-prometheus-stack-grafana -c grafana-sc-dashboard --tail=50
```

ConfigMap 하나가 수십 KiB라 client-side `kubectl apply`는 last-applied annotation 한도(256KiB)에 걸릴 수 있다.
Argo CD처럼 Server-Side Apply(`kubectl apply --server-side`)로 적용한다.
