# api-common

앱 전용 OpenBao 인증 리소스는 각 overlay의 `external-secrets/`에서 관리한다.
ESO 컨트롤러와 CRD 설치는 기존 `platform-external-secrets` Application이 담당한다.

| Overlay | Application | ServiceAccount | SecretStore / OpenBao Role |
| --- | --- | --- | --- |
| dev | apps-api-common-dev | eso-common-dev | openbao-common-dev / common-dev |
| prod | apps-api-common-prod | eso-common-prod | openbao-common-prod / common-prod |

dev와 prod 모두 workload와 인증 리소스를 함께 배포한다.
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
| GARAGE_ACCESS_KEY (dev) | apps/common/dev/image | garage-access-key |
| GARAGE_SECRET_KEY (dev) | apps/common/dev/image | garage-secret-key |

OpenBao DB 값은 실제 PostgreSQL
계정과 일치해야 한다. 앱 ExternalSecret은 DB 계정 비밀번호를 변경하지 않는다.

dev 앱 Secret은 ESO로 전환을 완료했고 기존 KSOPS `secret-generator.yaml`과 `secret.sops.env`는
삭제했다. Deployment는 기존 `api-common-secret` 참조를 유지하며, KSOPS의 해시 이름 대신
ESO의 고정 이름을 사용한다. CNPG DB 계정 Secret은 dev, prod 모두 ESO로 만든다([DB 계정](#db-계정)). GHCR pull Secret은 dev는 SOPS, prod는 ESO다.

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

## prod

| 항목 | dev | prod |
| --- | --- | --- |
| 도메인 | `commonplant-dev.okbear.dev` | `commonplant.okbear.dev` |
| DB | `postgres-dev` / `api_common` (reclaim `delete`) | `postgres-prod` / `api_common` (reclaim `retain`) |
| Garage bucket | `common-dev` | `common-prod` |
| GHCR pull Secret | KSOPS `overlays/dev/ghcr-secret.sops.yaml` | ESO `ghcr-pull-secret` ← `apps/common/prod/ghcr` |
| 이미지 | Kargo dev Stage 자동 승격 | Kargo prod Stage (dev 통과 Freight만) |

`apps-prod` AppProject는 Secret을 허용하지 않으므로 prod의 Secret은 모두 ExternalSecret이 만든다.
prod overlay에는 `images`가 없고 replicas가 0이다. Kargo prod Stage가 첫 digest를 커밋한 뒤
replicas를 올린다.

prod의 ExternalSecret은 키 7개를 읽는다. 하나라도 없으면 해당 Secret이 생성되지 않는다.

| OpenBao 경로 (mount `secret`) | 키 |
| --- | --- |
| `apps/common/prod/database` | `username`(`api_common`), `password` |
| `apps/common/prod/auth` | `jwt-secret` |
| `apps/common/prod/image` | `garage-access-key`, `garage-secret-key` (`common-prod` bucket 전용 key) |
| `apps/common/prod/ghcr` | `username`, `password` (classic PAT, `read:packages`) |

### DB 계정

DB 계정 비밀번호는 환경마다 OpenBao `apps/common/<env>/database` 한 곳에서 관리한다.
Kubernetes Secret은 다른 namespace에서 참조할 수 없으므로 같은 값을 ESO가 두 namespace에
각각 만든다. `<env>`는 `dev` 또는 `prod`다.

| namespace | Secret | 사용처 | SecretStore / OpenBao role |
| --- | --- | --- | --- |
| `api-common-<env>` | `api-common-secret` | 앱 `DB_USERNAME`, `DB_PASSWORD` | `openbao-common-<env>` / `common-<env>` |
| `postgres-<env>` | `api-common-db-secret-<env>` | CNPG `DatabaseRole` `passwordSecret` | `openbao-api-common-<env>` / `postgres-api-common-<env>` |

`postgres-<env>` 쪽 리소스는 `databases/postgres/overlays/<env>/api-common/external-secrets.yaml`에
있다. 상위 overlay가 이름에 `-<env>`를 붙이므로 참조 이름에는 suffix를 포함해 적는다. Secret에
`cnpg.io/reload` 라벨이 있어 값이 바뀌면 CNPG가 DB 비밀번호를 다시 적용한다.

`postgres-<env>` role의 policy는 DB 경로 하나만 읽는다. dev는 아래 명령의 `prod`를 `dev`로 바꾼다.

```bash
bao policy write postgres-api-common-prod - <<'EOF'
path "secret/data/apps/common/prod/database" {
  capabilities = ["read"]
}
EOF

bao write auth/kubernetes/role/postgres-api-common-prod \
  bound_service_account_names=eso-api-common-prod \
  bound_service_account_namespaces=postgres-prod \
  audience=openbao \
  token_policies=postgres-api-common-prod \
  token_ttl=1h token_max_ttl=4h
```

비밀번호를 바꿀 때는 OpenBao 값만 바꾼다. ESO가 두 Secret을 갱신하면(최대 `refreshInterval` 1시간)
CNPG가 DB 비밀번호를 바꾸고, 앱은 `rollout restart`로 새 값을 읽는다.

#### dev 전환

dev는 KSOPS가 만들던 `api-common-db-secret-dev`를 같은 이름의 ExternalSecret으로 바꿨다.
전환 전에 SOPS 값과 OpenBao 값이 같은지 확인한다. 다르면 sync 후 CNPG가 DB 비밀번호를
OpenBao 값으로 바꾼다. 앱도 OpenBao 값을 쓰므로 앱 접속은 유지되지만 의도하지 않은 변경이다.

```bash
f=gitops/databases/postgres/overlays/dev/api-common/db-auth-secret.sops.yaml  # 전환 전 main 기준
for k in username password; do
  a=$(sops -d --extract "[\"stringData\"][\"$k\"]" "$f" | shasum -a 256)
  b=$(bao kv get -mount=secret -field="$k" apps/common/dev/database | shasum -a 256)
  [ "$a" = "$b" ] && echo "$k same" || echo "$k DIFFERENT"
done
```

sync 후 ExternalSecret이 기존 Secret을 소유하지 못해 `SecretSyncedError`이면 KSOPS가 만든 Secret을
지워 ESO가 다시 만들게 한다. `DatabaseRole`은 reclaim `retain`이라 계정은 그대로 남는다.

```bash
kubectl -n postgres-dev describe externalsecret api-common-db-secret-dev
kubectl -n postgres-dev delete secret api-common-db-secret-dev   # 소유권 충돌일 때만
kubectl -n postgres-dev get secret api-common-db-secret-dev -o jsonpath='{.metadata.ownerReferences[0].kind}'
```

앱의 `application-prod.yml`은 `ddl-auto: validate`라 스키마를 만들지 않는다. 마이그레이션 도구가
없으므로 prod DB 스키마를 준비하지 않으면 첫 기동에서 실패한다.

```bash
kustomize build gitops/apps/api-common/overlays/prod
kubectl -n api-common-prod wait --for=condition=Ready secretstore/openbao-common-prod --timeout=120s
kubectl -n api-common-prod wait --for=condition=Ready externalsecret --all --timeout=120s
kubectl -n postgres-prod wait --for=condition=Ready externalsecret/api-common-db-secret-prod --timeout=120s
kubectl -n postgres-prod get databaserole,database
```
