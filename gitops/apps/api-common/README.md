# api-common

앱 전용 OpenBao 인증 리소스는 dev overlay의 `external-secrets/`에서 관리한다.
ESO 컨트롤러와 CRD 설치는 기존 `platform-external-secrets` Application이 담당한다.

| Overlay | Application | ServiceAccount | SecretStore / OpenBao Role |
| --- | --- | --- | --- |
| dev | apps-api-common-dev | eso-common-dev | openbao-common-dev / common-dev |

dev는 기존 workload와 인증 리소스를 함께 배포한다.
Namespace는 기존 namespaces Application이 관리한다.
수동 생성한 동일 이름의 SA는 삭제하지 않고 이 선언으로 관리한다.

OpenBao의 KV v2 `secret` 엔진, Kubernetes Auth, Role, Policy와 비밀값은 별도 구성한다.
Role은 dev SA 이름과 Namespace에 바인딩하고 audience는 `openbao`로 맞춘다.
Kubernetes API 주소는 꺾쇠괄호 없이 `https://kubernetes.default.svc:443`를 사용한다.
SecretStore는 내부 HTTP Service `platform-openbao.openbao.svc.cluster.local:8200`에 연결한다.

현재 ESO 2.9.0 차트는 컨트롤러 SA `external-secrets/platform-external-secrets`에
`serviceaccounts/token` 생성 권한을 부여하므로 별도 TokenRequest RBAC는 추가하지 않는다.
인증용 SA는 Pod에 마운트하지 않고 ESO가 TokenRequest로 토큰을 발급받는다.
앱 AppProject는 SA, SecretStore와 ExternalSecret을 허용하며 클러스터 범위 리소스는 계속 금지한다.
SA는 sync wave -3, SecretStore는 -2, ExternalSecret은 -1로 기본 wave의 workload보다 먼저 적용한다.
wave는 적용 순서를 지정한다. 실제 Secret 동기화 성공은 아래 검증 명령으로 확인한다.

dev ExternalSecret 하나가 고정 이름 `api-common-secret`을 생성한다.

| Kubernetes Secret 키 | OpenBao 엔진 내부 경로 | 원본 키 |
| --- | --- | --- |
| DB_USERNAME | apps/common/dev/database | username |
| DB_PASSWORD | apps/common/dev/database | password |
| JWT_SECRET | apps/common/dev/auth | jwt-secret |
| GARAGE_ACCESS_KEY (dev) | apps/common/dev/image | GARAGE_ACCESS_KEY |
| GARAGE_SECRET_KEY (dev) | apps/common/dev/image | GARAGE_SECRET_KEY |

dev 이미지 인증은 운영자가 구성한 `secret/apps/common/dev/image`의 대문자 키를 조회한다.
OpenBao DB 값은 실제 PostgreSQL
계정과 일치해야 한다. 앱 ExternalSecret은 DB 계정 비밀번호를 변경하지 않는다.

dev overlay의 앱 Secret용 KSOPS generator 연결을 제거했다. 기존 `secret-generator.yaml`과
`secret.sops.env`는 비활성 상태로 남겨두며 렌더링에 포함하지 않는다. Deployment는 기존
`api-common-secret` 참조를 유지하며, KSOPS의 해시 이름 대신 ESO의 고정 이름을 사용한다.
GHCR pull Secret과 CNPG DB 계정 Secret은 기존 방식으로 유지한다.

전환 전 기존 Deployment가 해시 Secret을 참조하는지 확인한다. 필요하면 먼저 ExternalSecret만
선적용하여 동기화 성공을 확인한 뒤 앱 변경을 sync한다. 고정 이름 Secret을 이미 다른 주체가
관리한다면 소유권 충돌을 해결한 뒤 전환한다. 롤아웃 성공 후 기존 해시 Secret 정리를 확인한다.
`envFrom` 값은 Secret 갱신만으로 실행 중인 컨테이너에 반영되지 않으므로 값 변경 후 앱을
재시작한다. Grafana와 Prometheus는 이번 범위에 포함하지 않는다.

정적 검증:

```bash
kustomize build gitops/apps/api-common/overlays/dev/external-secrets
helm template root-app gitops/clusters/homelab/root-app
```

dev 전체 렌더링은 기존 KSOPS 실행과 복호화 환경이 필요하다.
Argo CD sync 후 클러스터에서 다음을 확인한다.

```bash
kubectl -n api-common-dev get sa eso-common-dev
kubectl -n api-common-dev wait --for=condition=Ready secretstore/openbao-common-dev --timeout=120s
kubectl -n api-common-dev wait --for=condition=Ready externalsecret/api-common-secret --timeout=120s
kubectl -n api-common-dev get secret api-common-secret
kubectl -n api-common-dev rollout status deployment/api-common
```

SecretStore Ready는 인증 연결, ExternalSecret Ready는 KV 읽기와 Secret 동기화를 확인한다.
앱의 DB 연결과 인증 기능은 dev 배포 후 별도로 확인한다. 이전 별도 platform-external-secrets-config Application을 이미 배포했다면
기존 Application의 cascade 삭제로 SA와 SecretStore가 제거되지 않도록 소유권 이전을
조정한 뒤 새 앱 Application으로 sync해야 한다.
