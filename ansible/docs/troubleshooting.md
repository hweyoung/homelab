# Ansible 문제 해결

## 기본 확인 순서

```bash
pwd
git status --short
make inventory
make syntax
```

명령은 `infra-bastion`의 `ansible/` 루트에서 실행한다.

## 임시 디렉터리 오류

wrapper는 `ANSIBLE_LOCAL_TEMP=/tmp/ansible-local`, `TMPDIR=/tmp`를 설정한다. 권한 오류가
나면 `scripts/ansible-env.sh`가 로드됐는지와 디렉터리 생성 권한을 확인한다.

## Inventory 오류

```bash
./scripts/run-inventory.sh --graph
./scripts/run-inventory.sh --list >/dev/null
```

- `inventories/homelab/hosts.yml` 존재와 YAML parse 확인
- 정확한 네 node 이름 확인
- `kube_control_plane`, `kube_node`, `etcd`, `k8s_cluster` 확인

Inventory 원문에는 IP와 사용자가 있으므로 issue나 외부 로그에 첨부하지 않는다.

## Kubespray checkout 오류

```bash
make sync-kubespray
git -C kubespray describe --tags --exact-match
```

- checkout tag와 `kubespray_version` 일치
- `cluster.yml` 또는 `upgrade-cluster.yml` 존재
- `kubespray/ansible.cfg`, `kubespray/roles` 존재
- `.kubespray-venv/bin/ansible-playbook` 실행 가능

프로젝트 `.venv`와 `.kubespray-venv`를 합치지 않는다.

## Vault 및 SOPS 오류

```bash
./scripts/run-vault.sh view
```

값을 복사하거나 로그에 남기지 않고 key 존재 여부만 확인한다. `sops_age_private_key`는
저장소 `.sops.yaml`의 age public key와 짝이 맞아야 한다. 새 키로 기존 Secret을 덮지
않는다.

## 실행 실패

```bash
ls -1t runs/<operation>/ | head
```

1. `summary.md`
2. `metadata.yml`
3. `stdout.log`
4. `ansible.log`
5. `command.txt`

Secret이 발견되면 artifact를 공유하지 않고 credential 회전과 `no_log` 보완을 우선한다.

## Kubernetes context

이 workflow는 cluster 점검을 `k8s-master:/etc/kubernetes/admin.conf` 기준으로 수행한다.
수동 검증 전 target context인지 확인한다.

```bash
kubectl config current-context
kubectl cluster-info
```

target cluster가 아니거나 접근할 수 없다면 정적 분석과 live-cluster 검증을 구분한다.

## ArgoCD bootstrap 실패

1. Helm CLI
2. `argocd` namespace와 Gateway 접근 label
3. SOPS age Secret
4. 선택적 repository credential
5. ArgoCD Helm release
6. `gitops/bootstrap/root.yaml`
7. `root-app`의 `Synced` 및 `Healthy` 상태

검증 작업은 ArgoCD server/repo-server rollout과 `root-app` 상태를 제한 시간 동안 기다린다.
실패하면 repository credential, KSOPS mount와 child Application 상태를 차례로 확인한다.

private repository credential의 circular bootstrap은 Ansible이 out-of-band로 해결한다. 이
credential을 GitOps로 옮기기 전에 bootstrap 계약을 먼저 검토한다.

초기 admin password는 execution artifact에 남기지 않는다. 꼭 필요한 경우 권한이 제한된
관리 세션에서 `argocd-initial-admin-secret`을 직접 조회하고 출력값을 공유하지 않는다.
