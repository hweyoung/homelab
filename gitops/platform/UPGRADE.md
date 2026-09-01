# Platform component upgrade

Helm 기반 플랫폼 component의 application version과 chart version 대응은
`gitops/clusters/homelab/root-app/values.yaml`의 `platformVersions`에서 관리한다.
실제 배포 버전은 component별 `activeVersion`이며, 한 번에 한 component의 한 단계만
변경한다. 각 단계는 별도 commit으로 남기고 Argo CD health 검증 후 다음 단계로 진행한다.

Gateway API CRD는 chart 대응표가 필요하지 않으므로
`gitops/platform/gateway-api-crds/kustomization.yaml`의 단일 release URL로 관리한다.
버전 이력은 해당 파일의 주석과 Git commit에 남긴다.

## cert-manager

CRD는 Helm chart의 `crds.enabled=true` 설정으로 controller와 함께 갱신된다.

1. `1.16.1` -> `1.16.5`
2. `1.16.5` -> `1.17.4`
3. `1.17.4` -> `1.18.6`
4. `1.18.6` -> `1.19.6`
5. `1.19.6` -> `1.20.3`
6. `1.20.3` -> `1.21.1`

각 단계에서 controller, webhook, cainjector, ClusterIssuer 및 모든 Certificate의
Ready 상태를 확인한다. `v1.19.0`은 인증서 재발급 regression이 있으므로 사용하지 않는다.

Kubernetes 1.32에서는 cert-manager `1.20.3`에서 멈춘다. cert-manager 1.21의 공식 지원
범위는 Kubernetes 1.33 이상이므로, `1.21.1` 선택은 Kubernetes 1.33 upgrade 및 postcheck가
완료된 뒤에만 진행한다.

## Gateway API와 Traefik

Traefik 3.6은 Gateway API v1.4.0 CRD를 요구한다. CRD를 controller보다 먼저 올린다.

1. Traefik `3.2.0` -> `3.2.2`
2. Traefik `3.2.2` -> `3.3.6` -> `3.4.3` -> `3.5.3`
3. Gateway API `1.2.1` -> `1.3.0` -> `1.4.0`
4. GatewayClass, Gateway, HTTPRoute의 `Accepted`, `Programmed`, `ResolvedRefs` 확인
5. Traefik `3.5.3` -> `3.6.15`

이 저장소는 Standard channel 리소스만 사용한다. `TCPRoute`, `TLSRoute`, `UDPRoute`가
필요해지기 전에는 Experimental CRD bundle로 전환하지 않는다.

## 단계별 검증

```bash
helm template root-app gitops/clusters/homelab/root-app
kustomize build gitops/platform/gateway-api-crds

kubectl -n cert-manager get deploy,pod
kubectl get clusterissuer,certificate -A
kubectl get gatewayclass,gateway,httproute -A
kubectl -n traefik rollout status deployment/platform-traefik --timeout=5m
```

CRD 변경은 rollback보다 다음 버전으로 복구하는 것을 우선한다. 변경 전에는 cert-manager
리소스와 Gateway API 리소스를 백업하고, Secret 백업은 암호화된 저장소에만 보관한다.
