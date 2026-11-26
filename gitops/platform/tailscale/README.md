# tailscale

관리 도구를 tailnet 안에서만 접근하도록 Tailscale Operator를 배포합니다.
Operator가 Traefik의 tailnet 전용 Service(`platform-traefik-tailnet`)를 `homelab-gateway` 기기로 노출합니다.

```text
tailnet 사용자 → homelab-gateway → Traefik tailnet(8444) → internal-gateway → 관리 도구
외부 사용자 → Cloudflare Tunnel → Traefik websecure(8443) → public-gateway → Dex, 이미지, 앱 API
```

| 경로 | 내용 |
| --- | --- |
| `values.yaml` | Operator 배치와 기본 ProxyClass |
| `secrets/` | Operator 인증 정보 (SOPS) |
| `proxy-class/` | 프록시 Pod를 prod worker에 배치하는 ProxyClass |

## 사전 작업

1. tailnet 정책의 `tagOwners`에 `tag:k8s-operator`, `tag:k8s`를 등록합니다. `tag:k8s`의 owner는 `tag:k8s-operator`입니다.
2. Trust credential을 발급합니다. 권한은 Devices Core, Auth Keys(`tag:k8s-operator`), Services입니다.
3. 값을 암호화 파일에 넣습니다. 프롬프트 없이 입력을 기다리면 값을 붙여 넣고 Enter를 누릅니다.

   ```bash
   read -rs V; sops set gitops/platform/tailscale/secrets/operator-oauth.sops.yaml '["stringData"]["client_id"]' "\"$V\""; unset V
   ```

   ```bash
   read -rs V; sops set gitops/platform/tailscale/secrets/operator-oauth.sops.yaml '["stringData"]["client_secret"]' "\"$V\""; unset V
   ```

인증 정보 없이 배포하면 LoadBalancer Service에 주소가 할당되지 않아 `platform-traefik`가 Progressing에 머물고,
Argo CD Ansible 사전 점검도 실패합니다.

## 확인

```bash
kubectl -n tailscale get pods
```

```bash
kubectl -n traefik get svc platform-traefik-tailnet
```

`EXTERNAL-IP`에 `100.x` 주소가 보이면 DNS를 바꾸기 전에 그 주소로 직접 시험합니다.

```bash
curl -sI --resolve grafana.okbear.dev:443:<TAILSCALE_IP> https://grafana.okbear.dev/ | head -5
```

## 플랫폼 이전

1. HTTPRoute의 `parentRefs`에 `internal-gateway`의 `https`를 추가합니다.
2. Cloudflare DNS의 레코드를 Proxy를 끈 A 레코드 `<TAILSCALE_IP>`로 바꿉니다.
3. Tunnel의 public hostname을 제거하고 tailnet 밖에서 접속이 안 되는지 확인합니다.
4. Cloudflare Access 앱을 제거하고 HTTPRoute에서 `public-gateway`를 뺍니다.

Tunnel hostname을 지우기 전에 Access를 제거하면 관리 도구가 인증 없이 공개될 수 있습니다.
Dex, 이미지, 앱 API는 공개 경로를 유지합니다.
