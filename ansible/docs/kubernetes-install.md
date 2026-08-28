# 신규 Kubernetes 설치

## 적용 대상

이 절차는 아직 Kubernetes가 설치되지 않은 신규 node에만 사용한다. 기존 cluster의 version
변경에는 [kubernetes-upgrade.md](kubernetes-upgrade.md)를 사용한다.

```text
playbooks/site.yml
  → playbooks/kubernetes/bootstrap.yml
    → install.yml
      → kubespray: checkout과 cluster.yml 검증
      → kubernetes: target version 검증과 설치 필요 여부 판정
      → kubernetes: Inventory topology와 worker placement 사전 점검
      → kubespray: cluster.yml 실행
      → kubernetes: admin.conf, Node 등록, Ready와 version 사후 점검
    → node-config.yml → k8s_node_config
```

설치가 필요할 때의 lifecycle은 `validate → state → precheck → install → postcheck`이며,
실행 순서는 `playbooks/kubernetes/install.yml`이 소유한다. `roles/kubernetes/tasks/install/`의
각 파일은 상태 판정, 사전 점검, 사후 점검 명세만 담당한다.

## 사전 조건

- `infra-bastion`에서 실행
- `inventories/homelab/hosts.yml` 준비
- 모든 node SSH 접근 가능
- `kubespray_version`과 `kube_version` 검토
- `./scripts/prepare-bastion.sh` 실행 완료
- `.kubespray-venv`와 pinned `kubespray/` checkout 준비
- Tailscale 및 node network 연결 확인

```bash
make inventory
make syntax
make ssh-check
```

## 실행 순서

신규 환경 전체 bootstrap:

```bash
make bootstrap
```

단계별 실행:

```bash
make bastion-ssh
make bastion-hosts
make tailscale
make kubespray
make post-kubespray
make helm
make sops
make argocd
```

`make kubespray`는 `k8s-master:/etc/kubernetes/admin.conf`가 있으면 기존 cluster로 판단해
precheck, `cluster.yml`, postcheck를 건너뛴다. 이 파일 하나만으로 cluster 전체 health를
보장하는 것은 아니므로
부분 장애에서 `kubespray_force=true`를 즉시 사용하지 않는다.

설치 사전 점검은 Kubespray 필수 Inventory group, 고정 node 역할, worker의
`kube_node_pool`/`platform_tier` 계약을 검증한다. 설치 후에는 master의 `admin.conf`, 모든
Inventory node의 cluster 등록 여부, Node Ready 상태와 목표 kubelet version을 검증한다.

## ArgoCD handoff

```text
Ansible
  ├── Helm CLI
  ├── argocd namespace prerequisite
  ├── SOPS age Secret
  ├── 선택적 repository credential
  ├── ArgoCD Helm release
  └── gitops/bootstrap/root.yaml
          ↓
       ArgoCD GitOps ownership
```

root Application 적용 후 platform/application resource를 Ansible에 중복 추가하지 않는다.

## 강제 재실행

다음은 일반적인 drift 보정 명령이 아니다.

```bash
./scripts/run-playbook.sh kubespray-force playbooks/site.yml \
  --tags kubespray \
  -e kubespray_force=true
```

사용 전 cluster 상태, Kubespray release, Inventory와 node 구성을 확인한다. Kubernetes
업그레이드 목적으로 사용하지 않는다.

ArgoCD values가 바뀌면 동일 chart version에서도 자동으로 Helm reconcile을 수행한다.
외부 상태 복구 등으로 변경 감지와 관계없이 강제 reconcile이 필요할 때만 다음 명령을
사용한다.

```bash
./scripts/run-playbook.sh argocd-force playbooks/site.yml \
  --tags argocd \
  -e @secrets.yml \
  --ask-vault-pass \
  -e argocd_force=true
```

## 설치 후 확인

```bash
kubectl get nodes -o wide --show-labels
kubectl get pods -A
kubectl get applications.argoproj.io -A
```

- `k8s-worker-prod`: `pool=prod`, prod taint
- `k8s-worker-dev`: `pool=dev`, prod taint 없음
- `homelab.okbear.dev/environment`가 Inventory pool과 일치
