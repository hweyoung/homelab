# cert-manager-config

Cloudflare DNS-01 자격증명과 ClusterIssuer 를 관리합니다 (feature5 Task 5-3).

## 구성

| 파일 | 내용 | sync-wave |
| --- | --- | --- |
| `cloudflare-api-token.example.yaml` | Cloudflare API Token Secret **예시** (배포 안 됨) | — |
| `clusterissuer-staging.yaml` | Let's Encrypt staging ClusterIssuer | `-10` |
| `clusterissuer-prod.yaml` | Let's Encrypt production ClusterIssuer | `-10` |

root-app 에는 `cert-manager-config` Application(`directory`, wave `-20`)으로 등록되어 있으며,
`*.example.yaml` 은 렌더에서 제외되므로 배포되지 않습니다.

## 실제 Token 넣기

```bash
cp cloudflare-api-token.example.yaml cloudflare-api-token.sops.yaml
# stringData.api-token 에 실제 Cloudflare API Token(Zone DNS Edit + Zone Read) 입력 후
sops -e -i cloudflare-api-token.sops.yaml
git add cloudflare-api-token.sops.yaml
```

Token Secret 이 없으면 ClusterIssuer 의 `Ready` 가 `False` 로 남습니다(DNS-01 challenge 불가).
Secret 을 추가하면 cert-manager 가 자동으로 재시도합니다.

## 검증

```bash
kubectl get secret cloudflare-api-token -n cert-manager
kubectl get clusterissuer
kubectl describe clusterissuer letsencrypt-staging
```
