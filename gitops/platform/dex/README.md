# dex

Argo CD, Grafana 등 관리 도구가 공유하는 OIDC issuer입니다. GitHub로 로그인하고, GitHub Team을
`groups` claim(`<org>:<team slug>`)으로 전달합니다. 권한은 각 플랫폼의 RBAC에서 그룹별로 매핑합니다.

| 경로 | 내용 |
| --- | --- |
| `values.yaml` | GitHub connector와 OIDC client 목록 |
| `secrets/` | GitHub OAuth 자격 증명, client secret (SOPS) |
| `exposure/` | `dex.okbear.dev` HTTPRoute |

브라우저와 각 플랫폼 Pod가 모두 issuer에 접근해야 하므로 `public-gateway`에 노출합니다.
Cloudflare Access를 앞에 두면 Pod의 OIDC discovery가 막히므로 적용하지 않습니다.

## 사전 작업

1. `homelab-platform-org`에 `platform-admin`, `common-backend` Team을 만듭니다.
2. org에 OAuth App을 등록합니다. callback URL은 `https://dex.okbear.dev/callback`입니다.
3. OpenBao client secret을 생성합니다. Dex는 값이 없어도 빈 secret으로 기동하므로 merge 전에 꼭 넣습니다.

   ```bash
   sops set gitops/platform/dex/secrets/dex-env.sops.yaml '["stringData"]["OPENBAO_CLIENT_SECRET"]' "\"$(openssl rand -hex 32)\""
   ```

4. GitHub OAuth 자격 증명을 입력합니다.

   ```bash
   sops gitops/platform/dex/secrets/dex-env.sops.yaml
   ```

5. Grafana client secret을 OpenBao에 복사합니다.

   ```bash
   sops -d --extract '["stringData"]["GRAFANA_CLIENT_SECRET"]' gitops/platform/dex/secrets/dex-env.sops.yaml \
     | bao kv patch -mount=secret platform/monitoring/grafana oidc-client-secret=-
   ```

6. Cloudflare Tunnel에 `dex.okbear.dev`를 추가합니다.

## 배포 순서

merge하면 Dex와 Grafana는 Argo CD가 동기화합니다. Argo CD의 OIDC 설정은 Helm release가
소유하므로 merge 후 Ansible로 별도 반영합니다.

```bash
make -C ansible argocd-upgrade-reconcile
```

## 비상 접근

Argo CD와 Grafana의 로컬 admin 계정은 유지합니다. Dex나 GitHub에 장애가 나면 이 계정으로 로그인합니다.

## 플랫폼 추가

1. `values.yaml`의 `staticClients`에 client를 추가합니다.
2. `dex-env.sops.yaml`에 `secretEnv`로 지정한 값을 추가합니다.
3. 플랫폼에 OIDC를 설정하고 `<org>:<team slug>` 그룹을 권한에 매핑합니다.

그룹별 권한과 OpenBao, Grafana 적용 절차는 [access-control.md](../../../docs/gitops/access-control.md)에 있습니다.
