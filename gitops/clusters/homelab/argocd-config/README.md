# argocd-config — ArgoCD 자체 설정 (GitOps)

AppProject 등 **ArgoCD 자신의 설정**을 GitOps 로 관리하는 디렉토리입니다.
root-app 의 `values.yaml` 에 `argocd-config` Application 으로 등록되어 있으며,
`wave: -10` 으로 **가장 먼저 sync** 되어 다른 Application 이 참조할 AppProject 를
먼저 생성합니다.

```text
root-app (App-of-Apps)
└── argocd-config  (wave -10, project: default)   ← 여기
    └── projects/
        ├── platform.yaml    # cluster-scoped 허용
        ├── databases.yaml   # namespace 스코프 한정
        └── apps.yaml        # namespace 스코프 한정
```

> **self-reference 회피:** argocd-config 는 `project: default` 를 씁니다.
> platform project 가 아직 없는 시점에 sync 되어야 하므로, 자신을 platform
> project 로 두면 순환 참조가 됩니다. 부트스트랩 성격의 App 은 항상 존재하는
> `default` project 를 사용합니다.

---

## 권한 모델 (AppProject)

| project | source repo | destination namespace | cluster-scoped 리소스 | namespace-scoped 리소스 |
| --- | --- | --- | --- | --- |
| `platform` | homelab | cert-manager, traefik, gateway, cnpg-system, dex, minio, monitoring | ✅ 허용 (CRD/ClusterRole) | ✅ 허용 |
| `databases` | homelab | postgresql-dev, postgresql-prod | ❌ 차단 | ✅ 허용 |
| `apps` | homelab | common-app-dev, common-app-prod, toy-app-dev, toy-app-prod | ❌ 차단 | ✅ 허용 |

- **platform** 만 cluster-scoped 리소스(operator/CRD/ClusterRole)를 생성할 수 있습니다.
- **databases / apps** 는 `clusterResourceWhitelist: []` 로 cluster-scoped 리소스를
  전면 차단하고, namespace-scoped 리소스만 다룹니다.
- **apps** 는 하나의 공용 namespace 가 아니라 **앱별·환경별 namespace**(`<app>-<env>`,
  env ∈ dev·prod)로 분리 운영합니다. platform/databases 와 동일하게 destination 을
  명시적으로 열거하여 project 경계를 명확히 유지합니다.
- 각 project 는 **자신의 destinations 밖**에는 배포할 수 없습니다.
- `default` project 사용은 argocd-config(부트스트랩) 한정으로 최소화합니다.

새 서비스를 추가할 때는 해당 project 의 `destinations` 에 namespace 를 먼저 추가한 뒤
(apps 는 `<app>-<env>`), `root-app/values.yaml` 의 Application 에서 `project` 를 지정하세요.

---

## ArgoCD 설정 patch 항목

AppProject 외에 GitOps 로 관리할 수 있는 ArgoCD 설정입니다. 현재는 Ansible 부트스트랩이
초기 설치를 담당하므로, 아래 항목은 **이 디렉토리로 이관 대상**으로 정리해 둡니다.
(이관 시 `argocd-cm` / `argocd-rbac-cm` manifest 를 `projects/` 와 동일하게 추가)

| 대상 | 리소스 | 용도 |
| --- | --- | --- |
| RBAC 정책 | `argocd-rbac-cm` (ConfigMap) | project 별 팀 권한(role/group) 매핑 |
| 리포지토리 자격증명 | `argocd-repo-creds` (Secret) | private repo/helm registry 접근 |
| 부가 설정 | `argocd-cm` (ConfigMap) | resource exclusions, kustomize/helm 옵션 등 |

> 주의: 위 리소스를 GitOps 로 옮길 때는 Ansible 이 관리하는 값과 충돌하지 않도록,
> 소유권을 한쪽으로 명확히 정한 뒤 이관합니다.

---

## 검증

```bash
# argocd-config Application 상태
kubectl get application -n argocd argocd-config

# 생성된 AppProject
kubectl get appproject -n argocd
kubectl describe appproject platform -n argocd
```

### 권한 차단 확인 (Task 3-3)

의도한 권한 경계가 동작하는지 확인합니다.

- **cluster-scoped 차단:** `databases`/`apps` project 를 참조하는 Application 이
  CRD/ClusterRole 을 포함하면 sync 가 실패하고, ArgoCD UI/`status.conditions` 에
  다음과 유사한 메시지가 표시됩니다.

  ```text
  Application referencing project databases which does not permit
  cluster-scoped resource <group>/<kind>
  ```

- **destination 차단:** project 에 등록되지 않은 namespace 로 배포하면
  `application destination ... is not permitted in project ...` 오류가 납니다.

- **platform 허용:** `platform` project 는 CRD/ClusterRole 생성이 정상 sync 됩니다.

권한 오류는 Application 이 **Sync 단계에서 실패**하므로 실제 리소스가 생성되지 않습니다.
`kubectl describe application <name> -n argocd` 의 `Conditions` 에서 원인을 확인합니다.
