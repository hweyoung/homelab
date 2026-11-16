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
필요하지 않고 외부 진입점도 생기지 않습니다. 앱별 `Project`, `Warehouse`, `Stage`와
repository credential은 `gitops/apps/<앱>/kargo/`에 둡니다.

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
  -> apps-<앱>-kargo (30): Project, Warehouse, Stage, credential
```

| 경로 | Application | AppProject | 내용 |
| --- | --- | --- | --- |
| `platform/kargo/values.yaml` | `platform-kargo` | `platform` | CRD, controller, webhook |
| `apps/<앱>/kargo` | `apps-<앱>-kargo` | `kargo-pipelines` | 앱별 Project, Warehouse, Stage, credential |

Kargo `Project`는 cluster-scoped라 `apps-dev`/`apps-prod` AppProject에 둘 수 없습니다.
`platform`은 모든 리소스를 허용하므로 앱 파이프라인용 `kargo-pipelines` AppProject를 따로
두었습니다. 이 AppProject는 `kargo.akuity.io`의 `Project`, `ProjectConfig`, `Warehouse`,
`Stage`, `PromotionTask`와 credential용 `ServiceAccount`, `SecretStore`, `ExternalSecret`만
허용하고 배포 대상은 `kargo-api-*` namespace로 제한합니다.

argocd namespace의 `kargo-controller` Role/RoleBinding은
`argocd-control-plane/kargo-controller-rbac.yaml`이 소유합니다. chart도 같은 이름으로 만들기
때문에 values에서 `argocd.dataPlane.install`과 `argocd.dataPlane.kargoController.install`을
끕니다. 둘 중 하나만 끄면 Role이나 RoleBinding 하나가 남습니다.

### Namespace

Namespace metadata는 `gitops/platform/namespaces`만 소유합니다. Kargo chart의 Namespace
자동 생성을 끄고 namespace chart에 선언했습니다. Kargo chart는 각 namespace의 RBAC만
생성합니다. namespace 구분은 Kargo 설계를 따른 것입니다.

| Namespace | 용도 | 현재 |
| --- | --- | --- |
| `kargo` | controller, management controller, webhook Pod | 사용 |
| `kargo-<앱>` | Project namespace. Warehouse, Stage, Freight, Promotion, 앱별 credential | `kargo-api-common` 사용 |
| `kargo-shared-resources` | 모든 Project가 읽는 공용 Secret | 미사용. credential은 앱별로 둔다 |
| `kargo-system-resources` | ClusterConfig(클러스터 단위 webhook receiver)가 참조하는 Secret | 미사용. external webhook을 켤 때 사용 |
| `kargo-cluster-secrets` | `kargo-system-resources`의 이전 이름 | 미사용. 1.11 하위 호환 |

Kargo 1.11에는 `kargo-cluster-secrets` 설정이 하위 호환을 위해 남아 있습니다. 해당 설정은
1.12에서 제거될 예정이므로 Kargo minor upgrade 전에 chart migration note와
`kargo-system-resources` 전환 상태를 확인하고, 그때 이 namespace를 정리합니다.

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

1. `platform-kargo` Application이 `Synced/Healthy`이고 `argocd` namespace 리소스를 만들지 않는다.
2. Kargo controller, management controller, webhook Pod가 모두 Ready다.
3. webhook Certificate가 Ready이고 API server 호출 오류가 없다.
4. Kargo CRD 9개가 조회된다.
5. controller 로그에 Argo CD discovery 또는 RBAC 오류가 없다.

아직 이 저장소에서는 실클러스터 설치 결과를 검증하지 않았습니다. 위 조건을 확인하기
전까지 상태는 `구성 완료`가 아니라 `정적 검증 완료`로 기록합니다.

## api-common 파이프라인

`gitops/apps/api-common/kargo`는 `apps-api-common-kargo` Application이 관리합니다.

| 리소스 | 역할 |
| --- | --- |
| `Project` `kargo-api-common` | namespace는 `platform/namespaces`가 Project 라벨과 함께 먼저 만든다 |
| `ProjectConfig` | dev Stage만 자동 승격 |
| SA, SecretStore, ExternalSecret | OpenBao에서 GHCR·Git credential을 가져온다 |
| `Warehouse` `api-common` | `sha-<40자리 커밋>` 태그만 수집하고 빌드 시각이 가장 최근인 이미지를 고른다 |
| `Stage` `dev` | dev overlay에 digest를 고정해 `main`에 push하고 `apps-api-common-dev`를 sync |

`apps-api-common-dev`에는 `kargo.akuity.io/authorized-stage: kargo-api-common:dev`
annotation이 있어야 `argocd-update` step이 sync할 수 있습니다. dev overlay의 이미지는
이제 Kargo가 관리하므로 수동으로 수정하지 않습니다.

### Credential

credential은 Project마다 따로 둡니다. 이미지 저장소의 관리자가 앱마다 다를 수 있고,
토큰을 폐기하거나 교체할 때 영향 범위를 해당 앱으로 한정하기 위해서입니다. 앱마다
GitOps 저장소나 레지스트리가 달라도 같은 구조를 씁니다.

Kargo는 Project namespace에서 `kargo.akuity.io/cred-type` 라벨이 붙은 Secret을 `repoURL`로
찾습니다. 값은 OpenBao에 두고 `external-secrets.yaml`의 ExternalSecret이 라벨과 `repoURL`을
붙여 Secret을 만듭니다. token이나 key를 교체할 때는 OpenBao 값만 바꾸면 되고 Git 커밋은
필요 없습니다.

Kubernetes 쪽(SA, SecretStore, ExternalSecret)은 매니페스트로 관리합니다. OpenBao의 KV 값,
policy, Kubernetes Auth role은 Kubernetes 리소스가 아니므로 다른 앱과 같이
[OpenBao + ESO 문서](../../../docs/gitops/openbao-eso.md) 방식대로 CLI로 만듭니다.

| Secret | cred-type | repoURL | OpenBao 경로 (mount `secret`) |
| --- | --- | --- | --- |
| `ghcr-credentials` | `image` | `ghcr.io/umc-commonplant/api-common` | `platform/kargo/api-common/ghcr` |
| `git-credentials` | `git` | `https://github.com/hweyoung/homelab.git` | `platform/kargo/api-common/git` |

| 경로 | 키 | 값 |
| --- | --- | --- |
| `ghcr` | `username` | token을 만든 GitHub 사용자명 |
| `ghcr` | `password` | classic PAT, `read:packages`만. GHCR은 fine-grained token을 지원하지 않는다. token 소유자가 `umc-commonplant/api-common` package를 읽을 수 있어야 한다 |
| `git` | `githubAppClientID` | GitHub App의 Client ID (`Iv` 로 시작) |
| `git` | `githubAppInstallationID` | homelab에 설치한 App의 Installation ID (숫자) |
| `git` | `githubAppPrivateKey` | App에서 생성한 PEM private key 전체 |

GHCR은 GitHub App token을 받지 않고 Kargo의 image credential도 App 인증을 지원하지 않으므로
GHCR만 classic PAT를 씁니다. 지금은 개인 계정 token으로 시작하고, 조직 봇 계정이 생기면
package Read 권한만 준 봇 계정 token으로 바꿉니다.

#### GitHub App 준비

Git push는 PAT 대신 GitHub App을 씁니다. Kargo가 private key로 1시간짜리 installation
token을 그때그때 발급받으므로 token 만료를 관리할 필요가 없고 사람 계정과도 분리됩니다.
GitHub 권한 모델상 저장소 단위가 최소이므로 쓰기 범위는 PAT와 같이 homelab 저장소 전체입니다.

1. Settings → Developer settings → GitHub Apps → New GitHub App
   (저장소가 조직 소유이면 조직 설정의 Developer settings)
2. Webhook의 Active를 끈다. Repository permissions는 Contents: Read and write만 준다
   (Metadata: Read-only는 자동). 설치 범위는 Only on this account로 둔다.
3. 생성 후 Client ID를 기록하고, Generate a private key로 PEM을 내려받는다.
4. Install App → Only select repositories → `homelab`만 선택한다. 설치 후 URL 끝 숫자가
   Installation ID다.

같은 GitOps 저장소에 push하는 다른 Kargo Project도 이 App을 재사용할 수 있습니다. 이때
private key는 Project마다 따로 생성해 OpenBao에 넣으면 앱 단위로 key를 폐기할 수 있습니다.

#### OpenBao 값 넣기

token과 key가 shell history에 남지 않도록 stdin과 파일 참조(`@`)로 넣습니다.

```bash
read -rs GHCR_TOKEN && printf '%s' "$GHCR_TOKEN" \
  | bao kv put -mount=secret platform/kargo/api-common/ghcr username='<GitHub 사용자명>' password=- \
  && unset GHCR_TOKEN

bao kv put -mount=secret platform/kargo/api-common/git \
  githubAppClientID='<Client ID>' \
  githubAppInstallationID='<Installation ID>' \
  githubAppPrivateKey=@/path/to/app.private-key.pem
rm -P /path/to/app.private-key.pem
```

읽기 전용 policy를 만듭니다. KV v2이므로 경로에 `data/`가 들어갑니다.

```bash
bao policy write kargo-api-common - <<'EOF'
path "secret/data/platform/kargo/api-common/*" {
  capabilities = ["read"]
}
EOF
```

role을 만듭니다. SA 이름, namespace, audience가 SecretStore와 같아야 합니다.

```bash
bao write auth/kubernetes/role/kargo-api-common \
  bound_service_account_names=eso-kargo-api-common \
  bound_service_account_namespaces=kargo-api-common \
  audience=openbao \
  token_policies=kargo-api-common \
  token_ttl=1h token_max_ttl=4h
```

값은 출력하지 않고 키 이름만 확인합니다.

```bash
bao kv get -mount=secret -format=json platform/kargo/api-common/ghcr | jq '.data.data | keys'
bao kv get -mount=secret -format=json platform/kargo/api-common/git | jq '.data.data | keys'
bao policy read kargo-api-common
bao read auth/kubernetes/role/kargo-api-common
```

### 앱 추가

새 앱 `<앱>`의 파이프라인은 다음을 추가합니다.

1. `platform/namespaces/values.yaml`에 `kargo-<앱>` namespace와
   `kargo.akuity.io/project: "true"` 라벨
2. `gitops/apps/<앱>/kargo/`에 Project, ProjectConfig, Warehouse, Stage와
   `external-secrets.yaml`(SA `eso-kargo-<앱>`, SecretStore, ExternalSecret)
3. OpenBao `platform/kargo/<앱>/{ghcr,git}` 값, policy와 role `kargo-<앱>`
4. root-app에 `<앱>-kargo` 항목(`project: kargo-pipelines`)
5. 대상 Application에 `kargo.akuity.io/authorized-stage` annotation

### 배포 후 확인

```bash
kubectl get project,projectconfig
kubectl get secretstore,externalsecret -n kargo-api-common
kubectl get warehouse,freight,stage -n kargo-api-common
kubectl get promotion -n kargo-api-common
```

1. `apps-api-common-kargo`가 `Synced/Healthy`다.
2. SecretStore와 두 ExternalSecret이 Ready다.
3. Warehouse가 Ready이고 Freight가 생성된다.
4. dev Promotion이 `Succeeded`이고 `main`에 승격 커밋이 생긴다.
5. `apps-api-common-dev`가 해당 커밋으로 sync되고 dev Stage가 Healthy다.

## 다음 단계

1. dev 배포 뒤 HTTP smoke test를 추가합니다.
2. prod workload와 `api-common-prod` Application을 준비합니다.
3. prod Stage는 dev에서 검증된 Freight를 PR로 올리고, PR merge를 승인으로 사용합니다.
4. rollback은 과거 검증 Freight를 재승격해 Git 이력으로 남깁니다.
