# 관리 도구 접근 권한

GitHub Team을 Dex가 `groups` claim(`homelab-platform-org:<team slug>`)으로 전달하고, 각 플랫폼이 그룹별
권한을 정한다. 팀원 추가와 제거는 GitHub Team에서 한다.

| 대상 | `platform-admin` | `common-backend` | 설정 위치 |
| --- | --- | --- | --- |
| Argo CD | `role:admin` | 권한 없음 | `ansible/roles/argocd/templates/argocd-values.yaml.j2` |
| Grafana | Org Admin, 모든 대시보드 | Viewer, `10 Common Backend` 폴더 | `gitops/platform/monitoring/values.yaml`, 폴더 권한 |
| OpenBao | `platform-admin` 정책 | `secret/apps/common` 하위 읽기·쓰기 (dev, prod) | 아래 OpenBao 절차 |
| Garage UI (도입 예정) | `admin_roles` | 지정한 bucket | 도입 시 `access_control`에 설정 |
| bastion SSH | Tailscale SSH | 불가 | Tailscale 정책 (Dex와 무관) |

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

`common-backend`는 dev와 prod 모두 읽고 쓸 수 있다. prod 값을 바꾸면 ESO가 `refreshInterval` 안에 Secret으로
동기화한다. 버전 영구 삭제(`destroy`)와 metadata 삭제는 주지 않는다.

```bash
bao policy write common-backend - <<'EOF'
path "secret/data/apps/common/*" {
  capabilities = ["create", "read", "update", "patch", "delete"]
}
path "secret/metadata/apps/common/*" {
  capabilities = ["read", "list"]
}
path "secret/delete/apps/common/*" {
  capabilities = ["update"]
}
path "secret/undelete/apps/common/*" {
  capabilities = ["update"]
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
