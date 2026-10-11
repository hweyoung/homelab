# Kargo 이미지 승격 컨트롤 플레인

Kargo는 GHCR에 발행된 애플리케이션 이미지를 환경별 GitOps overlay로 승격합니다. 이미지
빌드와 Kubernetes 배포 사이의 책임을 분리하고, dev에서 검증한 artifact를 다시 빌드하지
않은 채 prod에 반영하기 위해 도입했습니다.

## 도입 배경

애플리케이션 소스와 CI는 팀이 사용하는 GitHub Organization 저장소에 있고, Kubernetes의
목표 상태는 개인 홈랩 저장소에 있습니다. 애플리케이션 GitHub Actions가 홈랩 저장소를
직접 수정하게 하면 두 저장소의 권한 경계가 흐려지고 CI credential의 영향 범위도
커집니다.

Kargo는 GHCR을 읽고 홈랩 GitOps 저장소만 수정합니다. 애플리케이션 CI는 테스트와 이미지
발행까지만 담당하며, 홈랩 배포 권한을 갖지 않습니다.

```text
Organization application repository
  -> GitHub Actions: test and build once
  -> GHCR: immutable tag and digest
  -> Kargo: discover and promote Freight
  -> Personal GitOps repository: update environment overlay
  -> Argo CD: reconcile the cluster
```

prod는 GHCR의 최신 이미지를 독립적으로 선택하지 않습니다. dev Stage에서 배포와 검증을
통과한 Freight만 전달받고, 같은 image digest를 사용합니다. 환경별 ConfigMap, Secret,
database endpoint와 domain은 승격 대상이 아니라 각 overlay의 상태로 유지합니다.

## 현재 구현 범위

이번 단계는 파이프라인보다 먼저 필요한 내부 컨트롤 플레인만 설치합니다.

- Kargo CRD와 controller
- Project namespace를 관리하는 management controller
- cert-manager 인증서를 사용하는 admission webhook
- Argo CD Application health 연동
- Freight와 Promotion 이력을 정리하는 garbage collector

API/UI와 external webhook은 비활성화했습니다. 따라서 admin password와 token signing key가
필요하지 않고 외부 진입점도 생기지 않습니다. repository credential, `Project`,
`Warehouse`, dev/prod `Stage`와 승인 정책은 별도 변경으로 추가합니다.

## 버전과 배치 기준

| 구성 요소 | 선언 버전 | 관계 |
| --- | --- | --- |
| Kubernetes | `1.34.3` | 현재 Kubespray 목표 버전 |
| Kargo | `1.11.0` | Kubernetes client `0.34.x` 계열 |
| cert-manager | `1.21.1` | Kargo admission webhook 인증서 발급 |
| Argo CD | `3.4.6` | Git 상태 적용과 Application health 제공 |

Kargo Pod는 prod worker에 배치합니다. 단일 worker 환경이므로 이 설정은 역할 분리이지
고가용성 구성이 아닙니다. prod worker 점검 중에는 promotion이 중단될 수 있지만, 이미
Git에 반영된 애플리케이션의 Argo CD 배포 상태에는 영향을 주지 않습니다.

## GitOps 소유권과 설치 순서

```text
platform/namespaces (-50)
  -> cert-manager (-35)
  -> platform-kargo (-11)
  -> Kargo Project and promotion pipeline (후속 변경)
```

Namespace metadata는 `gitops/platform/namespaces`만 소유합니다. Kargo chart의 Namespace
자동 생성을 끄고 `kargo`, `kargo-cluster-secrets`, `kargo-system-resources`,
`kargo-shared-resources`를 namespace chart에 선언했습니다. Kargo chart는 각 namespace의
RBAC만 생성합니다. root-app은 Helm Application 등록과 sync wave를 담당합니다.

Kargo 1.11에는 `kargo-cluster-secrets` 설정이 하위 호환을 위해 남아 있습니다. 해당 설정은
1.12에서 제거될 예정이므로 Kargo minor upgrade 전에 chart migration note와
`kargo-system-resources` 전환 상태를 확인해야 합니다.

## 정적 검증

OCI chart를 현재 values와 Kubernetes 1.34 조건으로 렌더해 설치 계약을 확인합니다.

```bash
helm template kargo oci://ghcr.io/akuity/kargo-charts/kargo \
  --version 1.11.0 \
  --namespace kargo \
  --kube-version 1.34.3 \
  -f gitops/platform/kargo/values.yaml

helm template root-app gitops/clusters/homelab/root-app
helm template namespaces gitops/platform/namespaces
git diff --check
```

현재 정적 렌더 결과는 9개 Kargo CRD와 `kargo-controller`,
`kargo-management-controller`, `kargo-webhooks-server` Deployment를 포함합니다. API와
external webhook Deployment 및 Namespace는 생성하지 않습니다. 정적 렌더 성공은 실제
Pod 기동, admission webhook TLS 또는 Argo CD 연동 성공을 의미하지 않습니다.

## 배포 후 확인

Argo CD가 `platform-kargo`를 sync한 뒤 대상 클러스터에서 확인합니다.

```bash
kubectl get application -n argocd platform-kargo
kubectl get pods -n kargo
kubectl get crd | grep kargo.akuity.io
kubectl get certificate,issuer -n kargo
kubectl get validatingwebhookconfiguration,mutatingwebhookconfiguration \
  | grep kargo
```

완료 기준은 다음과 같습니다.

1. `platform-kargo` Application이 `Synced/Healthy`다.
2. Kargo controller, management controller, webhook Pod가 모두 Ready다.
3. webhook Certificate가 Ready이고 API server 호출 오류가 없다.
4. Kargo CRD 9개가 조회된다.
5. controller 로그에 Argo CD discovery 또는 RBAC 오류가 없다.

아직 이 저장소에서는 실클러스터 설치 결과를 검증하지 않았습니다. 위 조건을 확인하기
전까지 상태는 `구성 완료`가 아니라 `정적 검증 완료`로 기록합니다.

## 다음 단계

1. `api-common` 전용 Kargo Project namespace와 AppProject 권한을 정의합니다.
2. GHCR read credential과 GitOps repository write credential을 SOPS로 관리합니다.
3. commit tag만으로 순서를 추측하지 않도록 Warehouse의 image 선택 정책을 정합니다.
4. dev overlay에는 새 Freight를 자동 반영하고 readiness와 HTTP smoke test를 수행합니다.
5. prod Stage는 dev에서 검증된 동일 digest만 수동 승인으로 승격합니다.
6. rollback은 과거 검증 Freight를 재승격해 Git 이력으로 남깁니다.
