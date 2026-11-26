# 팀원 로그인 안내

관리 도구는 GitHub 계정으로 로그인한다. Argo CD, Grafana, OpenBao, Garage 관리 UI는 Tailscale에 연결된
상태에서만 열린다. 권한은 GitHub Team에 따라 정해진다([접근 권한](access-control.md)).

## 처음 한 번

1. **GitHub 조직 초대 수락**: `homelab-platform-org` 초대 메일을 수락한다. 관리자가 팀
   (`platform-admin` 또는 `common-backend`)에 추가해야 권한이 생긴다.
2. **Tailscale 초대 수락**: 관리자가 보낸 tailnet 초대 링크로 가입한다.
3. **Tailscale 앱 설치와 로그인**: [다운로드](https://tailscale.com/download) 후 초대받은 계정으로 로그인한다.
   메뉴 막대 아이콘에서 `Connected`인지 확인한다.

## 접속 주소

| 도구 | 주소 | 경로 | 로그인 |
| --- | --- | --- | --- |
| Argo CD | https://argocd.okbear.dev | tailnet | `LOG IN VIA GITHUB` |
| Grafana | https://grafana.okbear.dev | tailnet | `Sign in with GitHub` |
| OpenBao | https://openbao.okbear.dev | tailnet | Method `OIDC`, Role 비우면 `common-backend` |
| Garage 관리 UI | https://garage.okbear.dev | tailnet | `GitHub`로 로그인 |
| Kargo | https://kargo.okbear.dev | 공개 | SSO 로그인 |

처음 로그인하면 Dex를 거쳐 GitHub 권한 승인 화면이 나온다. `homelab-platform-org`의 `platform-admin`,
`common-backend` 팀 멤버만 로그인할 수 있고, 그 밖의 계정은 Dex에서 거절된다.

OpenBao에서 `platform-admin` 권한이 필요하면 Role에 `platform-admin`을 넣는다.

## CLI

```bash
argocd login argocd.okbear.dev --sso
```

```bash
kargo login https://kargo.okbear.dev --sso --port 8085
```

```bash
BAO_ADDR=https://openbao.okbear.dev bao login -method=oidc role=common-backend
```

Argo CD와 OpenBao CLI도 Tailscale이 연결되어 있어야 한다. Kargo CLI는 포트를 `8085`로 고정해야 Dex가
redirect를 받아 준다.

## 문제 해결

| 증상 | 원인 | 조치 |
| --- | --- | --- |
| 페이지가 열리지 않거나 시간 초과 | Tailscale 연결 끊김 | Tailscale 앱에서 연결 확인 |
| Tailscale을 켰는데도 403·525 | 예전 DNS 응답이 캐시됨 | 아래 명령으로 DNS 캐시 비우기 |
| Dex에서 로그인 거절 | GitHub Team 미소속, 조직 초대 미수락 | 관리자에게 팀 추가 요청 후 다시 로그인 |
| Kargo CLI에서 `Unregistered redirect_uri` | `--port 8085` 누락 | 포트를 붙여 다시 실행 |

macOS DNS 캐시 비우기:

```bash
sudo dscacheutil -flushcache; sudo killall -HUP mDNSResponder
```
