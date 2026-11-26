# 관리 도구 접근 권한

GitHub Team을 Dex가 `groups` claim(`homelab-platform-org:<team slug>`)으로 전달하고, 각 플랫폼이 그룹별
권한을 정한다. 팀원 추가와 제거는 GitHub Team에서 한다.

| 대상 | `platform-admin` | `common-backend` | 설정 위치 |
| --- | --- | --- | --- |
| Argo CD | `role:admin` | 권한 없음 | `ansible/roles/argocd/templates/argocd-values.yaml.j2` |
| Grafana | Org Admin, 모든 대시보드 | Viewer, `10 Common Backend` 폴더 | `gitops/platform/monitoring/values.yaml`, 폴더 권한 |
| OpenBao | `platform-admin` 정책 | `secret/apps/common` 하위 dev 읽기·쓰기, prod 읽기 (`prod/image` 거부) | 아래 OpenBao 절차 |
| Kargo | admin | viewer, 모든 Project 조회 | `gitops/platform/kargo/values.yaml` `api.oidc` |
| Garage 관리 UI | 모든 bucket·key 관리 | `common-dev` 조회·업로드·삭제, `common-prod` 조회 | `gitops/platform/garage/ui/config.yaml` `access_control` |
| bastion SSH | Tailscale SSH | 불가 | Tailscale 정책 (Dex와 무관) |

tailnet 접근 경로와 전환 절차는 [tailscale README](../../gitops/platform/tailscale/README.md)에 있다.
팀원에게는 [로그인 안내](team-login.md)를 공유한다.

Argo CD와 Grafana의 로컬 admin 계정, OpenBao 복구 수단은 Dex와 GitHub 장애에 대비한 비상 접근용으로 유지한다.

## OpenBao

정책과 OIDC 인증은 [openbao-eso.md](openbao-eso.md)의 정책과 같이 `bao` CLI로 적용한다.
Dex의 `dex-env`에 `OPENBAO_CLIENT_SECRET`이 있고 Dex가 배포된 뒤 관리자 토큰으로 실행한다.

### 정책

`platform-admin`은 root 토큰 대신 평소에 쓰는 관리자 정책이다. 정책 변경 권한이 있으므로 root와 권한 차이는
크지 않지만, 사용자별 토큰과 만료 시간이 남는다.

```bash
bao policy write platform-admin - <<'EOF'
path "*" {
  capabilities = ["create", "read", "update", "patch", "delete", "list", "sudo"]
}
EOF
```

`common-backend`는 dev를 읽고 쓰고, prod는 읽기만 한다. prod 값 변경은 `platform-admin`이 하고 ESO가
`refreshInterval` 안에 Secret으로 동기화한다. prod Garage 앱 key(`prod/image`)는 읽기도 막는다. 버전 영구
삭제(`destroy`)와 metadata 삭제는 주지 않는다.

```bash
bao policy write common-backend - <<'EOF'
# dev: 읽기·쓰기, soft delete와 복구
path "secret/data/apps/common/dev/*" {
  capabilities = ["create", "read", "update", "patch", "delete"]
}
path "secret/delete/apps/common/dev/*" {
  capabilities = ["update"]
}
path "secret/undelete/apps/common/dev/*" {
  capabilities = ["update"]
}
# prod: 읽기만. 값 변경과 삭제는 platform-admin이 한다.
path "secret/data/apps/common/prod/*" {
  capabilities = ["read"]
}
# prod Garage 앱 key는 쓰기 권한이 있어 읽는 것만으로 관리 UI의 prod 읽기 전용을 우회한다.
path "secret/data/apps/common/prod/image" {
  capabilities = ["deny"]
}
path "secret/metadata/apps/common/*" {
  capabilities = ["read", "list"]
}
EOF
```

상위 경로 목록 권한이 없으므로 팀원은 UI에서 `secret/kv/list/apps/common/` 경로로 직접 들어간다.

### OIDC 인증

```bash
bao auth enable -path=oidc -listing-visibility=unauth jwt
```

```bash
sops -d --extract '["stringData"]["OPENBAO_CLIENT_SECRET"]' gitops/platform/dex/secrets/dex-env.sops.yaml \
  | bao write auth/oidc/config oidc_discovery_url=https://dex.okbear.dev oidc_client_id=openbao oidc_client_secret=- default_role=common-backend
```

```bash
bao write auth/oidc/role/platform-admin - <<'EOF'
{
  "role_type": "oidc",
  "user_claim": "sub",
  "bound_audiences": ["openbao"],
  "bound_claims": { "groups": ["homelab-platform-org:platform-admin"] },
  "oidc_scopes": ["profile", "email", "groups"],
  "allowed_redirect_uris": [
    "https://openbao.okbear.dev/ui/vault/auth/oidc/oidc/callback",
    "http://localhost:8250/oidc/callback"
  ],
  "token_policies": ["platform-admin"],
  "token_ttl": "8h"
}
EOF
```

```bash
bao write auth/oidc/role/common-backend - <<'EOF'
{
  "role_type": "oidc",
  "user_claim": "sub",
  "bound_audiences": ["openbao"],
  "bound_claims": { "groups": ["homelab-platform-org:common-backend"] },
  "oidc_scopes": ["profile", "email", "groups"],
  "allowed_redirect_uris": [
    "https://openbao.okbear.dev/ui/vault/auth/oidc/oidc/callback",
    "http://localhost:8250/oidc/callback"
  ],
  "token_policies": ["common-backend"],
  "token_ttl": "8h"
}
EOF
```

UI 로그인에서 Method를 `OIDC`로 고르고 Role에 위 역할 이름을 넣는다. 비우면 `common-backend`로 로그인한다.

## Garage

팀원은 GitHub Team으로 관리 UI(`https://garage.okbear.dev`)에 로그인해 자기 bucket을 다룬다. S3 key는
애플리케이션만 쓰고 사람에게 나눠 주지 않는다.

| 그룹 | 권한 | 설정 |
| --- | --- | --- |
| `platform-admin` | 모든 bucket·key·클러스터 관리 | `auth.oidc.admin_roles` |
| `common-backend` | `common-dev*` 조회·업로드·삭제, `common-prod*` 조회 | `access_control.teams` |
| 그 외 | Dex에서 거부 | Dex `teams` |

- 팀 권한은 garage-ui가 검사하는 UI 계층 권한이다. UI는 admin token 하나로 Garage를 호출하므로 Garage가
  사용자별로 강제하지 않는다. 팀원을 신뢰할 수 있는 내부 인원으로 보고 선택했다.
- `bucket_prefixes`는 접두사 비교다. bucket 이름이 다른 bucket 이름의 접두사가 되지 않게 짓는다.
- 팀은 prod 앱 key 경로(`secret/apps/<app>/prod/image`)를 읽을 수 없다. 앱 key는 쓰기 권한이 있어 관리 UI의
  prod 읽기 전용을 우회하기 때문이다. OpenBao 정책에서 `deny`로 막고, 이 경로의 key 교체는 `platform-admin`이
  한다. ESO는 별도 정책(`common-prod`)으로 읽으므로 영향이 없다.
- 새 애플리케이션은 `<app>-<env>` bucket, 앱 key, OpenBao 경로, GitHub Team, `access_control.teams` binding을
  한 묶음으로 만든다. 새 Team은 Dex `teams`에도 추가한다.

팀원이 빠지면 GitHub Team에서 제거한다. 남은 garage-ui 세션은 `session_max_age`(8h)까지 유효하므로 즉시
끊으려면 garage-ui Pod를 재시작한다. JWT 서명 키가 `emptyDir`이라 모든 세션이 무효가 된다.

```bash
kubectl -n garage rollout restart deploy/garage-ui
```

## Grafana

Team Sync와 데이터소스 권한은 Enterprise 기능이다. 현재는 폴더 권한으로 **보이는 대시보드만** 제한한다.
Viewer는 데이터소스 API로 임의 쿼리를 보낼 수 있으므로 다른 namespace의 지표와 로그를 완전히 막지는 못한다.

### 폴더 권한

Viewer를 `common-backend`만 쓰므로 `10 Common Backend` 폴더에만 Viewer 조회 권한을 남긴다. 폴더 권한은 Git에
선언하지 않으므로, sidecar가 폴더를 만든 뒤 한 번 실행하고 **새 폴더를 추가할 때마다 다시 실행**한다.
새 폴더는 기본적으로 Viewer가 볼 수 있다.

```bash
kubectl -n monitoring port-forward svc/platform-kube-prometheus-stack-grafana 3000:80
```

다른 터미널에서 실행한다.

```bash
AUTH="$(kubectl -n monitoring get secret grafana-admin -o jsonpath='{.data.admin-user}' | base64 -d):$(kubectl -n monitoring get secret grafana-admin -o jsonpath='{.data.admin-password}' | base64 -d)"
curl -su "$AUTH" http://localhost:3000/api/folders | jq -r '.[] | [.uid, .title] | @tsv' | while IFS=$'\t' read -r uid title; do
  if [ "$title" = "10 Common Backend" ]; then items='{"items":[{"role":"Viewer","permission":1}]}'; else items='{"items":[]}'; fi
  curl -su "$AUTH" -X POST -H 'Content-Type: application/json' -d "$items" "http://localhost:3000/api/folders/$uid/permissions" >/dev/null && echo "applied: $title"
done
```

### 데이터까지 분리할 때

대시보드는 데이터소스를 변수로 받으므로 JSON을 크게 고치지 않고 옮길 수 있다.

1. `role_attribute_path`를 `org_mapping`으로 바꿔 `common-backend`를 별도 Grafana org에 배정한다.
2. 그 org에 Prometheus 라벨 강제 프록시를 거치는 데이터소스를 만든다.
3. Loki를 멀티 테넌트로 전환하고 namespace별 테넌트를 데이터소스에 지정한다.
4. `10 Common Backend` 대시보드를 새 org에 프로비저닝한다.
