# ArgoCD Upgrade Runbook

이미 설치된 `argocd/argocd` Helm release를 별도 workflow로 업그레이드한다. 신규 설치,
SOPS age/PAT Secret 주입과 root Application 생성은 기존 `make argocd` bootstrap 경로가
계속 소유한다.

```text
신규 설치: playbooks/bootstrap.yml → platform/argocd/install.yml → helm install
기존 upgrade: playbooks/upgrade.yml --tags argocd_upgrade_* → precheck → upgrade → postcheck
```

## 준비

`inventories/homelab/group_vars/all.yml`의 목표 chart version을 변경한다.

```yaml
argocd_chart_version: "7.8.0"
```

실행 전에 Argo CD와 argo-helm release note에서 중간 major version, Kubernetes 호환성,
CRD 변경과 values migration을 확인한다. Kubernetes 업그레이드와 ArgoCD 업그레이드는 같은
maintenance 작업에서 동시에 수행하지 않는다.

## 실행

모든 명령은 `infra-bastion`의 `ansible/` 루트에서 실행한다.

```bash
make argocd-upgrade-precheck
```

precheck는 기존 release가 `deployed`이고 목표 chart가 더 높은 version인지 확인한다. 또한
ArgoCD Pod, 세 CRD와 모든 Application의 `Synced/Healthy` baseline을 검사한다. 결과와 upstream
release note를 검토한 후에만 실행한다.

```bash
make argocd-upgrade
```

이 target만 `argocd_upgrade_confirm=true`를 전달한다. Helm은 기존 Ansible-owned values로
`--atomic --wait --wait-for-jobs` upgrade를 수행하며 실패하면 release를 rollback한다. Secret과
root Application은 이 workflow에서 변경하지 않는다.

`make argocd` bootstrap은 기존 release를 발견하면 chart와 values를 유지하므로 upgrade를
우회할 수 없다.

사후 점검만 다시 수행할 수 있다.

```bash
make argocd-upgrade-postcheck
```

독립 postcheck는 동일한 현재/목표 version을 허용하고 release version/status, ArgoCD Pod Ready,
모든 Application의 `Synced/Healthy` 복구를 검증한다.

동일 chart version에서 values만 reconcile해야 할 때는 일반 chart upgrade와 구분해 명시적으로
승인한다.

```bash
make argocd-upgrade-reconcile
```

두 Playbook은 같은 `argocd` Role의 `validate.yml`, `precheck.yml`, `deploy.yml`,
`postcheck.yml`을 사용하며 `argocd_operation`으로 최초 설치와 upgrade 정책을 구분한다.

## 실패 시

다음 chart version으로 진행하지 않는다. `runs/argocd-upgrade/<run-id>/`의 `summary.md`,
`stdout.log`, metadata와 `helm history argocd -n argocd`를 확인한다. `--atomic` rollback 후에도
Application이 비정상이면 repository 연결, repo-server/CMP plugin, CRD conversion과 controller
로그를 확인한다. bootstrap target이나 Secret 재주입을 복구 수단으로 무조건 재실행하지 않는다.
