# argocd-control-plane — Argo CD 자체 설정 (GitOps)

AppProject 등 **Argo CD 자신의 설정**을 GitOps로 관리하는 디렉토리입니다.
root-app의 `values.yaml`에 `argocd-control-plane` Application으로 등록되어 있으며,
`wave: -100`으로 **가장 먼저 sync**되어 다른 Application이 참조할 AppProject를
먼저 생성합니다.

```text
root-app (App-of-Apps)
└── argocd-control-plane  (wave -100, project: default)   ← 여기
    ├── kargo-controller-rbac.yaml  # Kargo controller의 Application patch 권한
    └── projects/
        ├── argocd-system.yaml  # argocd namespace
        ├── platform.yaml       # cluster-scoped 허용
        ├── databases.yaml      # DB namespace 한정
        ├── apps-dev.yaml       # api-*-dev
        └── apps-prod.yaml      # api-*-prod
```

> **self-reference 회피:** argocd-control-plane은 `project: default`를 씁니다.
> AppProject가 아직 없는 시점에 sync되어야 하므로, 자신을 다른 project에 두면
> 순환 참조가 됩니다. 부트스트랩 성격의 App은 항상 존재하는 `default` project를 사용합니다.

---

## 권한 모델 (AppProject)

| project | destination namespace | cluster-scoped 리소스 | namespace-scoped 리소스 |
| --- | --- | --- | --- |
| `argocd-system` | argocd | ❌ 차단 | ✅ 전체 |
| `platform` | default, cert-manager, traefik, cloudflare-system, cnpg-system, local-path-storage, monitoring, external-secrets, openbao, garage, kargo 등 | ✅ 전체 | ✅ 전체 |
| `databases` | postgres-dev, postgres-prod, infisical | Namespace만 | ✅ 전체 |
| `apps-dev` | `api-*-dev` | ❌ 차단 | SA, SecretStore, ExternalSecret, Deployment, Service, ConfigMap, Secret, LimitRange, ResourceQuota, NetworkPolicy, HTTPRoute |
| `apps-prod` | `api-*-prod` | ❌ 차단 | SA, SecretStore, ExternalSecret, Deployment, Service, ConfigMap, HTTPRoute |

- source repo는 모두 homelab 저장소로 한정합니다. 정확한 목록은 `projects/*.yaml`이 기준입니다.
- **platform**만 operator/CRD/ClusterRole 같은 cluster-scoped 리소스를 생성할 수 있습니다.
- **apps-dev/apps-prod**는 namespace 패턴과 허용 kind를 whitelist로 제한하며, prod가 더 좁습니다.
  prod whitelist에는 `Secret` kind가 없으므로 앱 Secret은 ExternalSecret으로 만듭니다.
- 각 project는 **자신의 destinations 밖**에는 배포할 수 없습니다.
- `default` project 사용은 argocd-control-plane(부트스트랩) 한정으로 최소화합니다.

새 서비스를 추가할 때는 namespace가 project의 destination 패턴에 맞는지, 필요한 kind가
whitelist에 있는지 먼저 확인한 뒤 `root-app/values.yaml`의 Application에서 `project`를 지정하세요.

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
# argocd-control-plane Application 상태
kubectl get application -n argocd argocd-control-plane

# 생성된 AppProject
kubectl get appproject -n argocd
kubectl describe appproject platform -n argocd
```

### 권한 차단 확인 (Task 3-3)

의도한 권한 경계가 동작하는지 확인합니다.

- **cluster-scoped 차단:** `apps-dev`/`apps-prod` project 를 참조하는 Application 이
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
