# Garage object storage

Kubernetes 1.34에서 동작하는 단일 노드 Garage S3 호환 스토리지입니다. 공식 이미지
`dxflrs/garage:v2.3.0`을 고정해 사용하며, operator나 cluster-wide RBAC은 추가하지 않습니다.

## 설계 경계

- `Deployment/Recreate`: 같은 LMDB metadata PVC를 두 프로세스가 동시에 열지 않습니다.
- `dev` worker + `local-path`: metadata 1Gi, object data 50Gi를 해당 노드 로컬 디스크에 둡니다.
- `replication_factor = 1`: 분산 복제나 고가용성이 없는 단일 노드 구성입니다.
- S3 API `garage.garage.svc:3900`은 클러스터 내부 전용입니다. 외부에는 정적 이미지 조회용
  S3 website 포트만 `https://images.okbear.dev`의 path 기반 proxy를 통해 공개하고 RPC/Admin
  API는 노출하지 않습니다.
- RPC/Admin token은 최초 시작 시 metadata PVC의 `garage.toml`에 mode `0600`으로 생성됩니다.
  Git/Kubernetes Secret에 평문을 남기지 않으며 PVC가 유지되는 재시작에는 같은 값을 사용합니다.
- `metrics_token`은 두지 않습니다. `/metrics`는 클러스터 내부 Service `garage:3903`에서 토큰 없이
  수집하고 admin API는 `admin_token`이 계속 보호합니다. init container가 시작할 때마다 기존
  설정의 `metrics_token` 줄을 제거합니다.
- `garage` Deployment/Service selector는 `app.kubernetes.io/component: server`로 web-proxy Pod와
  분리합니다. Deployment selector는 immutable이므로 이 변경을 처음 적용할 때는
  `kubectl -n garage delete deployment garage` 후 Argo CD sync로 다시 만듭니다. PVC는 유지됩니다.
- 두 PVC에는 `Prune=false`가 있어 Application 삭제나 rename이 곧 데이터 삭제로 이어지지 않습니다.

## 배포 및 확인

root-app sync 후 다음 상태를 확인합니다.

```bash
kubectl -n garage rollout status deploy/garage --timeout=5m
kubectl -n garage get pod,pvc,svc
kubectl -n garage exec deploy/garage -- /garage status
```

Garage v2.3의 `server --single-node`가 최초 실행에서 단일 노드 layout을 자동 적용하므로 별도의
`layout assign/apply`는 필요하지 않습니다. 정상 상태에서도 bucket과 S3 access key는 자동으로
만들지 않습니다.

```bash
# bucket 생성
kubectl -n garage exec deploy/garage -- /garage bucket create common-dev

# access key 생성 (출력에는 secret key가 포함되므로 터미널/로그 취급에 주의)
kubectl -n garage exec deploy/garage -- /garage key create app-common-dev

# 위 명령이 출력한 key ID를 사용해 bucket 권한 부여
kubectl -n garage exec deploy/garage -- \
  /garage bucket allow --read --write --key <KEY_ID> common-dev
```

애플리케이션의 endpoint/region은 각각 `http://garage.garage.svc:3900`, `garage`입니다.
발급한 S3 access/secret key는 Git에 기록하지 말고 SOPS 또는 External Secrets로 소비
namespace에 전달합니다.

## 권한 분리

Garage 권한은 key와 bucket 사이의 `read`/`write`/`owner`뿐입니다. bucket policy나 prefix 단위
권한이 없으므로 **bucket이 권한 경계**입니다. 애플리케이션과 환경마다 bucket을 나누고 key를 공유하지
않습니다.

- bucket 이름은 `<app>-<env>`입니다. 공개 website bucket과 비공개 파일 bucket은 분리합니다
  (`common-prod`, `common-prod-private`).
- 애플리케이션 key와 사람이 쓰는 key를 나눕니다. 팀원이 빠지면 사람용 key만 교체하고 앱은 재배포하지
  않습니다.
- key에 `owner`를 주지 않습니다. `owner`는 S3 API로 website, CORS 같은 bucket 설정을 바꿀 수 있습니다.
  bucket 설정은 관리자가 CLI나 관리 UI에서 합니다.
- prod의 사람용 key는 읽기 전용이 기본입니다. 쓰기가 필요할 때만 잠시 `--write`를 부여하고 회수합니다.

| bucket | key | 권한 | OpenBao 경로 (`secret/`) |
| --- | --- | --- | --- |
| `common-dev` | `app-common-dev` | read, write | `apps/common/dev/image` |
| `common-prod` | `app-common-prod` | read, write | `apps/common/prod/image` |
| `common-dev` | `team-common-backend-dev` | read, write | `apps/common/dev/storage-console` |
| `common-prod` | `team-common-backend-prod` | read | `apps/common/prod/storage-console` |

사람용 key를 앱 경로 아래에 두면 OpenBao의 기존 팀 정책(`common-backend`)으로 해당 팀만 받아 갈 수
있습니다. bucket이나 key를 추가·회수하면 이 표도 함께 고칩니다. 현재 권한은 다음 명령으로 확인합니다.

```bash
kubectl -n garage exec deploy/garage -- /garage bucket info common-prod
kubectl -n garage exec deploy/garage -- /garage key info app-common-prod
```

모든 bucket은 같은 Garage 프로세스와 `dev` worker의 PVC에 있습니다. bucket 분리는 권한 경계이고 장애나
디스크 격리 경계는 아닙니다.

### UI 접근

| 용도 | 대상 | 인증 | 경계 |
| --- | --- | --- | --- |
| 관리 UI (bucket·key·권한 관리) | `platform-admin` | Dex OIDC | UI가 admin token을 쓰므로 Garage 관리자 권한과 같음 |
| 데이터 조회·업로드 | 각 팀 | 사람용 S3 key | Garage가 key-bucket 권한으로 직접 제한 |

관리 UI의 bucket별 접근 제어는 UI 내부 기능이고 보안 경계가 아닙니다. 팀에게 관리 UI를 열지 않습니다.
Garage v2 admin token scope도 API 단위라 bucket별로 제한할 수 없습니다. 팀원은 OpenBao에서 받은
사람용 key로 S3 클라이언트(Cyberduck, rclone 등)나 S3 key로 로그인하는 웹 브라우저를 사용합니다.
S3 API와 admin API는 계속 공개 경로에 노출하지 않습니다.

## 관리 UI 배포

`ui/`는 [garage-ui](https://github.com/Noooste/garage-ui) `v0.14.0`을 `https://garage.okbear.dev`에 배포합니다
(root-app의 `platform-garage-ui`).

- 로그인은 Dex OIDC만 씁니다. 비밀번호와 admin token 로그인은 항상 전체 관리자라 끕니다.
- `admin_roles`에 `homelab-platform-org:platform-admin`만 두고 `access_control: {}`로 기본 거부를 켭니다.
  다른 Dex 사용자는 로그인해도 모든 API가 403입니다.
- Garage 연결에는 PVC의 master `admin_token` 대신 `garage admin-token create`로 만든 UI 전용 토큰을 씁니다.
  회수할 때 Garage 설정과 재시작 없이 이 토큰만 지웁니다.
- 객체 조회·업로드는 UI가 해당 bucket 권한이 있는 key의 secret을 admin API로 읽어 처리합니다.
- JWT 서명 키는 `emptyDir`에 두므로 Pod가 바뀌면 다시 로그인합니다.

merge 전에 다음을 준비합니다. Dex의 `GARAGE_UI_CLIENT_SECRET`은 `dex-env.sops.yaml`에 들어 있습니다.

```bash
# UI 전용 admin token. 출력되는 token은 다시 볼 수 없다.
kubectl -n garage exec deploy/garage -- /garage admin-token create garage-ui
kubectl -n garage exec deploy/garage -- /garage admin-token info garage-ui
```

`admin-token info`의 Scope가 전체(`*`)인지 확인합니다. OpenBao에는 다음을 적용합니다. `bao`는
`platform-openbao-0` Pod 안에서 관리자 토큰으로 실행합니다.

```bash
bao policy write garage - <<'EOF'
path "secret/data/platform/garage/*" {
  capabilities = ["read"]
}
EOF

bao write auth/kubernetes/role/garage \
  bound_service_account_names=eso-garage \
  bound_service_account_namespaces=garage \
  audience=openbao \
  policies=garage \
  ttl=1h
```

값은 age 개인키가 있는 저장소 체크아웃에서 표준 입력으로 넘겨 명령 인자에 드러나지 않게 합니다.
`ADMIN_TOKEN`에는 위에서 만든 토큰을 붙여 넣습니다. 미리 `kubectl -n openbao exec -it platform-openbao-0 -- bao login`이
필요합니다.

```bash
read -rs ADMIN_TOKEN
CLIENT_SECRET="$(sops -d --extract '["stringData"]["GARAGE_UI_CLIENT_SECRET"]' gitops/platform/dex/secrets/dex-env.sops.yaml)"
printf '{"admin-token":"%s","oidc-client-secret":"%s"}' "$ADMIN_TOKEN" "$CLIENT_SECRET" \
  | kubectl -n openbao exec -i platform-openbao-0 -- bao kv put secret/platform/garage/ui -
unset ADMIN_TOKEN CLIENT_SECRET
```

Cloudflare Tunnel Public Hostname에 `garage.okbear.dev`를 다른 관리 도구와 같은 Traefik 서비스로 추가합니다.
merge 후 확인합니다.

```bash
kubectl -n garage wait --for=condition=Ready externalsecret/garage-ui --timeout=120s
kubectl -n garage rollout status deploy/garage-ui --timeout=5m
kubectl -n dex rollout status deploy/dex --timeout=5m
```

`platform-admin`으로 로그인해 bucket 목록이 보이는지, `common-backend` 계정은 권한 없음 화면이 나오는지
확인합니다. UI 전용 토큰을 회수할 때는 `/garage admin-token delete garage-ui`를 실행합니다.

## 외부 이미지 URL과 Bucket Routing

외부에는 `images.okbear.dev` 하나만 사용합니다. `garage-web-proxy`가 첫 번째 path segment를
명시적으로 허용된 Garage bucket으로 변환하고, 나머지 path를 object key로 전달합니다.

```text
GET https://images.okbear.dev/common-dev/images/example.webp
  ↓
Host: common-dev.okbear.dev
GET /images/example.webp
  ↓
Garage website endpoint :3902
  ↓
bucket=common-dev, key=images/example.webp
```

외부 DNS에는 `common-dev.okbear.dev`를 등록하지 않습니다. 이 값은 Garage가 bucket을 선택할
수 있도록 proxy가 내부 요청에만 설정하는 Host header입니다. Garage의 기존
`root_domain = ".okbear.dev"` 설정은 변경하지 않습니다.

현재 공개 tenant allowlist는 다음과 같습니다.

| 외부 prefix | Garage bucket |
| --- | --- |
| `/common-dev/` | `common-dev` |
| `/common-prod/` | `common-prod` |

각 bucket은 별도로 website access를 허용해야 익명 GET이 가능합니다.

```bash
kubectl -n garage exec deploy/garage -- /garage bucket create common-dev
kubectl -n garage exec deploy/garage -- \
  /garage bucket website --allow --index-document index.html common-dev
```

`common-dev` bucket에 `images/example.webp` key로 업로드하면 조회 URL은 다음과 같습니다.

```text
https://images.okbear.dev/common-dev/images/example.webp
```

새 bucket을 공개하려면 `proxy-nginx.conf`에 정확한 `location`과 내부 Host mapping을
추가합니다. 임의의 첫 path segment를 동적으로 bucket으로 전달하지 않습니다. Kustomize가
ConfigMap 이름에 content hash를 붙이고 Deployment 참조를 갱신하므로 설정 변경 시 proxy가
자동으로 rollout됩니다. 새 경로만 검증한 뒤 사용합니다.

HTTPRoute 배포와 별도로 Cloudflare Tunnel의 Public Hostname이 `images.okbear.dev`를 현재
Traefik 서비스로 전달하는지도 확인해야 합니다. website access는 bucket 전체의 익명 읽기를
허용하므로 비공개 파일과 같은 bucket을 사용하지 않습니다. Upload는 계속 인증된 내부 S3 API
`garage.garage.svc:3900`을 사용하고, 공개 proxy는 `GET`과 `HEAD` 요청만 허용합니다.

```bash
kubectl -n garage rollout status deploy/garage-web-proxy --timeout=5m
kubectl -n garage get deploy,svc garage-web-proxy

curl -I https://images.okbear.dev/common-dev/images/example.webp
curl -I https://images.okbear.dev/common-prod/images/example.webp
```

## 운영 주의사항

`local-path` PVC는 `k8s-worker-dev` 장애나 디스크 손실을 복구해 주지 않습니다. Garage의
metadata snapshot만으로 object data를 복원할 수도 없습니다. 실제 데이터를 넣기 전에 metadata와
data PVC를 함께 백업하고 복구 시험을 해야 합니다. 다중 노드로 전환할 때는 PVC/노드 수,
anti-affinity, zone/capacity layout, replication factor를 함께 재설계해야 하며 단순 replica 증가로
전환하면 안 됩니다.
