# gateway

공용 진입 Gateway 를 관리합니다 (feature5 Task 5-7, repo 컨벤션의 단일 `gateway` ns).

| 파일 | 내용 |
| --- | --- |
| `gatewayclass.yaml` | GatewayClass `traefik` (controller `traefik.io/gateway-controller`) |
| `certificate.yaml` | wildcard 인증서 `okbear.dev`, `*.okbear.dev` → Secret `wildcard-okbear-tls` |
| `gateway.yaml` | Gateway `public` (HTTP 8000 / HTTPS 8443 listener) |

* listener port 는 Traefik entryPoint(`web` 8000 / `websecure` 8443)와 일치한다.
* HTTPRoute 는 각 앱 namespace 에서 `parentRefs` 로 `gateway/public` 을 참조한다
  (`allowedRoutes.namespaces.from: All`). 필요 시 라벨 셀렉터로 좁힐 수 있다.
* 인증서 발급에는 `cert-manager-config` 의 `letsencrypt-prod` ClusterIssuer 와
  Cloudflare API Token Secret 이 필요하다.

## 검증

```bash
kubectl get gatewayclass
kubectl get certificate -n gateway
kubectl get secret wildcard-okbear-tls -n gateway
kubectl get gateway -n gateway
kubectl describe gateway public -n gateway   # Accepted / Programmed = True
```
