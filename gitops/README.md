# gitops — GitOps (App-of-Apps)

ArgoCD 가 소유하는 **클러스터 상태**의 진입점. Ansible 부트스트랩이 ArgoCD 를 설치하고
`bootstrap/root.yaml` 을 최초 1회 적용하면, 그 이후의 모든 Application 은 여기(GitOps)에서
선언적으로 관리됩니다.

```text
terraform/  →  ansible/  →  gitops/ (이 폴더, GitOps)
   VM        부트스트랩       클러스터 상태
```

> 모노레포(`hweyoung/homelab`) 운영 — GitOps 콘텐츠는 이 저장소의 `gitops/` 하위에 있습니다.
> 따라서 ArgoCD Application 의 `source.path` 는 **repo 루트 기준**(`gitops/...`)으로 지정합니다.
> 실제 repo URL / revision 은 `bootstrap/root.yaml` 에서 관리합니다.

---

## 디렉토리 구조

```text
gitops/
├── bootstrap/
│   └── root.yaml                     # 최초 1회 적용하는 root Application
├── clusters/
│   └── homelab/
│       ├── root-app/                 # App-of-Apps Helm 차트
│       │   ├── Chart.yaml
│       │   ├── values.yaml           # 관리할 Application 목록 (여기만 수정)
│       │   └── templates/
│       │       └── application.yaml  # applications 순회 + 이름/syncPolicy 규칙 렌더링
│       └── argocd-config/            # ArgoCD 자체 설정 (wave -10, project default)
│           ├── README.md             # 권한 모델 / 설정 patch 항목
│           └── projects/             # AppProject 권한 경계
│               ├── platform.yaml     #   cluster-scoped 허용
│               ├── databases.yaml    #   namespace 스코프 한정
│               └── apps.yaml         #   namespace 스코프 한정
├── SECRETS.md                        # SOPS+age Secret 관리 정책
└── issues/                           # 기획/이슈 참고 문서
```

> **Secret 관리 / CI**: 민감정보는 SOPS+age 로 암호화한 `*.sops.yaml` 로만 커밋합니다
> ([SECRETS.md](SECRETS.md)). PR 시 `.github/workflows/gitops-validate.yml` 이
> Helm/Kustomize 렌더·미암호화 Secret·평문/placeholder·금지 파일을 검증합니다.

동작 흐름:

1. `root.yaml` → `root-app` Application 생성 (path: `gitops/clusters/homelab/root-app`)
2. `root-app` 이 `values.yaml` 의 `applications` 목록을 Helm 으로 렌더링
3. `argocd-config`(wave -10)가 먼저 sync 되어 AppProject(권한 경계)를 생성
4. 나머지 항목이 각 AppProject 를 참조하는 ArgoCD Application 이 되어 서비스를 sync

권한 경계는 `argocd-config` 가 관리합니다 —
[argocd-config/README.md](clusters/homelab/argocd-config/README.md) 참고.
`platform` 은 cluster-scoped 리소스를 허용하고, `databases`/`apps` 는 namespace
스코프로 제한됩니다. Application 은 `values.yaml` 에서 `project` 로 이를 참조합니다.

---

## Application 추가하기

`clusters/homelab/root-app/values.yaml` 의 `applications` 에 항목을 추가하면 끝입니다.
root-app 이 다음 sync 때 대응 Application 을 생성합니다.

| 필드 | 필수 | 설명 |
| --- | --- | --- |
| `name` | ✅ | Application 기본 이름 |
| `namespace` | ✅ | 배포 대상 네임스페이스 |
| `path` | ✅ | repo 루트 기준 경로 (예: `gitops/apps/podinfo`) |
| `group` | | 이름 접두사(`<group>-<name>`) + `app.homelab/group` 라벨 |
| `project` | | ArgoCD AppProject (기본 `default`) |
| `type` | | `helm` \| `kustomize` \| `directory` (기본 `directory`) |
| `wave` | | `argocd.argoproj.io/sync-wave` (작을수록 먼저, 기본 `0`) |
| `createNamespace` | | `true` 면 `CreateNamespace=true` 를 syncOptions 에 병합 |
| `syncPolicyRef` | | `syncPolicies` 의 키 (기본 `manual`) |
| `repoURL` / `targetRevision` | | `global.*` override |
| `annotations` | | Application annotations 병합 |
| `helm` / `kustomize` | | 타입별 source 옵션 (그대로 렌더링) |

`syncPolicyRef` 는 `values.yaml` 의 `syncPolicies` 에 정의된 명명 정책(`manual`, `auto`)을
가리킵니다. 정책을 새로 만들면 여러 Application 이 동일한 sync 규칙을 공유할 수 있습니다.

---

## 적용 (최초 1회)

ArgoCD 가 설치된 뒤(= ansible `make argocd` 완료) root Application 을 한 번만 적용합니다.

```bash
kubectl apply -f bootstrap/root.yaml
```

이후에는 이 명령을 다시 칠 필요가 없습니다. `root-app` 자신을 포함한 모든 변경은 git 에
push 하고 ArgoCD 가 sync 하면 반영됩니다.

> Ansible 의 `argocd` role(`root_app.yml`)이 부트스트랩 끝에서 이 apply 를 대신 수행합니다.
> 수동 적용은 재해 복구나 로컬 검증용입니다.

---

## 검증

```bash
# 렌더링 결과 확인 (클러스터 없이)
helm template root-app clusters/homelab/root-app

# root.yaml manifest 검증
kubectl apply --dry-run=client -f bootstrap/root.yaml

# 적용 후 상태
kubectl get application -n argocd
kubectl describe application root-app -n argocd
```

정상이라면 `root-app` 과 `values.yaml` 에 정의한 하위 Application 들이 모두 조회됩니다.

---

## root-app Sync 실패 시 점검 순서

1. `kubectl describe application root-app -n argocd` — `Conditions` / `Message` 확인
2. repo 접근 오류: `root.yaml` 의 `repoURL` / `targetRevision` / 자격증명 확인
3. 렌더링 오류: `helm template root-app clusters/homelab/root-app` 를 로컬에서 재현
4. 하위 Application 미생성: `values.yaml` 의 `path` / `namespace` 필수값 누락 여부 확인
5. 권한 오류: 대상 `project` 의 AppProject 가 해당 repo/namespace 를 허용하는지 확인

---

## 삭제 / 복구

```bash
# root-app 만 제거 (finalizer 로 하위 Application 도 함께 정리됨)
kubectl delete application root-app -n argocd

# 하위 App 은 남기고 root 만 떼고 싶다면 finalizer 를 먼저 제거
kubectl patch application root-app -n argocd \
  --type merge -p '{"metadata":{"finalizers":[]}}'
kubectl delete application root-app -n argocd --cascade=orphan

# 복구: 다시 최초 적용
kubectl apply -f bootstrap/root.yaml
```
