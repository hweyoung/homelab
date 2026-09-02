# Garage object storage

Kubernetes 1.34에서 동작하는 단일 노드 Garage S3 호환 스토리지입니다. 공식 이미지
`dxflrs/garage:v2.3.0`을 고정해 사용하며, operator나 cluster-wide RBAC은 추가하지 않습니다.

## 설계 경계

- `Deployment/Recreate`: 같은 LMDB metadata PVC를 두 프로세스가 동시에 열지 않습니다.
- `dev` worker + `local-path`: metadata 1Gi, object data 50Gi를 해당 노드 로컬 디스크에 둡니다.
- `replication_factor = 1`: 분산 복제나 고가용성이 없는 단일 노드 구성입니다.
- S3 API `garage.garage.svc:3900`은 클러스터 내부 전용입니다. 외부에는 정적 이미지 조회용
  S3 website 포트만 `https://images.okbear.dev`로 공개하고 RPC/Admin API는 노출하지 않습니다.
- RPC/Admin token은 최초 시작 시 metadata PVC의 `garage.toml`에 mode `0600`으로 생성됩니다.
  Git/Kubernetes Secret에 평문을 남기지 않으며 PVC가 유지되는 재시작에는 같은 값을 사용합니다.
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
kubectl -n garage exec deploy/garage -- /garage bucket create commonplant

# access key 생성 (출력에는 secret key가 포함되므로 터미널/로그 취급에 주의)
kubectl -n garage exec deploy/garage -- /garage key create commonplant

# 위 명령이 출력한 key ID를 사용해 bucket 권한 부여
kubectl -n garage exec deploy/garage -- \
  /garage bucket allow --read --write --owner --key <KEY_ID> commonplant
```

애플리케이션의 endpoint/region은 각각 `http://garage.garage.svc:3900`, `garage`입니다.
발급한 S3 access/secret key는 Git에 기록하지 말고 SOPS 또는 External Secrets로 소비
namespace에 전달합니다.

## 외부 이미지 URL

`images.okbear.dev`는 Garage의 S3 API가 아니라 읽기 전용 website endpoint로 연결됩니다.
hostname과 동일한 `images` bucket을 만들고 website access를 허용해야 익명 GET이 가능합니다.

```bash
kubectl -n garage exec deploy/garage -- /garage bucket create images
kubectl -n garage exec deploy/garage -- \
  /garage bucket website --allow --index-document index.html images
```

이미지를 `images` bucket의 `products/example.webp` key로 업로드하면 조회 URL은 다음과 같습니다.

```text
https://images.okbear.dev/products/example.webp
```

HTTPRoute 배포와 별도로 Cloudflare Tunnel의 Public Hostname 또는 wildcard ingress가
`images.okbear.dev`를 현재 Traefik 서비스로 전달하는지도 확인해야 합니다. website access는
bucket 전체의 익명 읽기를 허용하므로 비공개 파일과 같은 bucket을 사용하지 않습니다.

## 운영 주의사항

`local-path` PVC는 `k8s-worker-dev` 장애나 디스크 손실을 복구해 주지 않습니다. Garage의
metadata snapshot만으로 object data를 복원할 수도 없습니다. 실제 데이터를 넣기 전에 metadata와
data PVC를 함께 백업하고 복구 시험을 해야 합니다. 다중 노드로 전환할 때는 PVC/노드 수,
anti-affinity, zone/capacity layout, replication factor를 함께 재설계해야 하며 단순 replica 증가로
전환하면 안 됩니다.
