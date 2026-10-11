# Ansible — 홈랩 부트스트랩 자동화

이 디렉터리는 Terraform이 VM을 만든 뒤 Kubernetes와 ArgoCD를 부트스트랩하는 단계까지
소유한다. ArgoCD root Application이 적용된 이후의 platform과 application resource는
`gitops/`가 지속적으로 관리한다.

> 이 문서는 `2026-09-08` 현재 저장소에 선언된 구성과 실행 경로를 기준으로 한다. 버전과
> 대상 호스트는 실행 전에 Inventory를 다시 확인한다.

```text
Terraform (Mac)
    ↓ VM 생성
Ansible / Kubespray (infra-bastion)
    ↓ Kubernetes + ArgoCD bootstrap
ArgoCD / GitOps
    ↓ platform + application reconciliation
```

상세 책임과 노드 구조는 [architecture.md](docs/architecture.md)를 참고한다.

## 현재 선언 기준

| 항목 | 선언 값 | 소유 위치 |
| --- | --- | --- |
| Kubespray | `v2.30.0` | `inventories/homelab/group_vars/all.yml` |
| Kubernetes | `1.34.3` | `inventories/homelab/group_vars/all.yml` |
| Helm CLI | `v3.19.5` | `inventories/homelab/group_vars/all.yml` |
| Argo CD | app `3.4.6`, chart `10.2.2` | Inventory와 `argocd_version_matrix` |

클러스터는 단일 control plane과 dev/prod worker 각 한 대, `local-path` 볼륨을 전제로 한다.
따라서 Kubernetes 업그레이드 중 workload 중단이 발생할 수 있고, stateful workload의 자동
failover나 스토리지 HA를 보장하지 않는다.

## 빠른 시작

모든 명령은 `infra-bastion`의 `ansible/` 디렉터리에서 실행한다.

먼저 Terraform이 VM을 생성했고 bastion에서 모든 노드로 SSH 접속할 수 있어야 한다.
실제 Inventory는 예제에서 복사한 뒤 호스트 주소와 접속 사용자를 환경에 맞게 설정한다.

```bash
cp inventories/homelab/hosts.yml.example inventories/homelab/hosts.yml
cp secrets.yml.example secrets.yml
./scripts/prepare-bastion.sh
./scripts/run-vault.sh encrypt
make inventory
make syntax
make ssh-check
```

`prepare-bastion.sh`는 Rocky/RHEL 계열의 `dnf` 환경을 전제로 하며, 프로젝트 Ansible용
`.venv`와 pinned Kubespray용 `.kubespray-venv`를 분리해 준비한다.

`secrets.yml`에는 환경에 따라 다음 값을 설정한다.

- `tailscale_auth_key`
- `.sops.yaml` 공개키와 짝이 맞는 `sops_age_private_key`
- private Git 저장소를 사용할 때만 `argocd_repo_pat`

실제 값은 출력하거나 커밋하지 않는다. `sops_age_private_key`는 기존 SOPS 암호문과 짝이
맞아야 하며, 노드에서 임의로 새 키를 만들지 않는다.

신규 환경 전체 bootstrap:

```bash
make bootstrap
```

`make all`은 controller 준비부터 전체 bootstrap까지 연속 실행한다. 이미 운영 중인
클러스터에서는 의도하지 않은 전체 흐름을 피하기 위해 필요한 단계의 Make target을 직접
선택한다.

bootstrap이 끝나면 Ansible은 Argo CD release와 root Application까지만 관리한다. Namespace,
Operator, Gateway, 데이터베이스와 애플리케이션을 Ansible에 추가하지 않고 기존 `gitops/`
owner와 sync wave를 따른다.

## 공식 실행 인터페이스

Makefile을 운영 API로 사용한다.

| 명령 | 책임 | Vault |
| --- | --- | --- |
| `make bastion-ssh` | Bastion SSH, SELinux, firewalld | 불필요 |
| `make bastion-hosts` | Bastion `/etc/hosts` | 불필요 |
| `make tailscale` | Tailscale 설치 및 Tailnet join | 필요 |
| `make kubespray` | 신규 cluster `cluster.yml` 실행 | 불필요 |
| `make post-kubespray` | kubeconfig, node label, taint | 불필요 |
| `make helm` | Helm CLI 최초 설치 | 불필요 |
| `make helm-upgrade-precheck` | 기존 Helm CLI upgrade 사전 점검 | 불필요 |
| `make helm-upgrade` | 승인된 Helm patch/minor upgrade | 불필요 |
| `make helm-upgrade-major` | 추가 승인된 Helm major upgrade | 불필요 |
| `make helm-upgrade-postcheck` | Helm upgrade 사후 점검 | 불필요 |
| `make sops` | ArgoCD namespace SOPS age Secret | 필요 |
| `make argocd` | ArgoCD 최초 설치와 root Application bootstrap | 필요 |
| `make kubernetes-upgrade-precheck` | 기존 cluster upgrade 사전 점검 | 불필요 |
| `make kubernetes-upgrade` | 승인된 Kubernetes upgrade | 불필요 |
| `make kubernetes-upgrade-postcheck` | upgrade 사후 점검 | 불필요 |
| `make argocd-upgrade-precheck` | 기존 ArgoCD release와 Application 사전 점검 | 불필요 |
| `make argocd-upgrade` | 승인된 ArgoCD Helm chart upgrade | 불필요 |
| `make argocd-upgrade-reconcile` | 동일 chart version의 승인된 values reconcile | 불필요 |
| `make argocd-upgrade-postcheck` | ArgoCD upgrade 사후 점검 | 불필요 |

점검 및 utility 명령:

```bash
make inventory
make syntax
make ssh-check
make vault
```

Kubernetes 신규 설치와 기존 cluster 업그레이드는 서로 다른 operation이다. 업그레이드에
`make kubespray` 또는 `kubespray_force=true`를 사용하지 않는다.

## 운영 변경 원칙

- `make bootstrap`과 `make argocd`는 신규 설치 경로다. 기존 release의 version 변경을
  bootstrap으로 우회하지 않는다.
- Kubernetes, Helm, Argo CD 업그레이드는 각각 precheck, 명시적 승인 target, postcheck
  순서로 한 component씩 수행한다.
- Kubernetes는 downgrade와 minor 건너뛰기를 거부한다. `local-path` PVC, PDB, stateful Pod를
  자동으로 강제 삭제하지 않는다.
- Argo CD upgrade는 Secret과 root Application을 변경하지 않는다. 동일 chart의 values만
  다시 맞출 때는 `make argocd-upgrade-reconcile`을 사용한다.
- node label과 prod taint의 desired state는 `make post-kubespray`가 소유한다. 업그레이드
  도중 임시 제거된 prod taint는 성공 여부와 관계없이 복원하도록 구성되어 있다.
- SOPS age private key, Vault 값, PAT, kubeconfig와 초기 비밀번호를 로그나 이슈에 남기지
  않는다.

자세한 사전·사후 체크리스트는 component별 runbook을 따른다. 특히 Kubernetes와 Argo CD를
같은 maintenance 작업에서 동시에 올리지 않는다.

## 실행 이력

운영 Playbook target은 `scripts/run-playbook.sh`를 통해 실행되며 다음 artifact를 남긴다.

```text
runs/<operation>/<run-id>/
├── metadata.yml
├── command.txt
├── ansible.log
├── stdout.log
└── summary.md
```

`runs/`는 Git 비추적 runtime 데이터다. 디렉터리는 `0700`, 파일은 `0600`으로 생성된다.
inline extra-vars는 제한된 비민감 제어 변수 외에는 command history에서 가려진다. 자세한
내용은 [execution.md](docs/execution.md)를 참고한다.

## 디렉터리 구조

```text
ansible/
├── playbooks/                       # 역할별 orchestration
│   ├── bootstrap.yml                # 최초 구성 root entrypoint
│   ├── upgrade.yml                  # component별 upgrade root entrypoint
│   ├── bastion/{ssh,hosts}.yml
│   ├── network/tailscale.yml
│   ├── kubernetes/{install,node-config,upgrade}.yml
│   └── platform/
│       ├── helm/{install,upgrade}.yml
│       └── argocd/{install,upgrade}.yml
├── roles/                           # 실제 검증과 상태 변경
│   ├── kubespray/                   # upstream checkout과 install/upgrade 실행
│   ├── kubernetes/                  # version, health, install/upgrade gate
│   ├── k8s_node_config/             # kubeconfig, label, taint 수렴
│   ├── helm/                        # Helm CLI install/upgrade
│   └── argocd/                      # bootstrap과 승인된 release upgrade
├── inventories/homelab/             # host와 선언 version의 기준
├── scripts/                         # 환경 준비와 공식 실행 wrapper
├── runs/                            # Git 비추적 execution artifact
└── docs/
```

`playbooks/bootstrap.yml`은 최초 구성, `playbooks/upgrade.yml`은 기존 환경 변경의 root
entrypoint다. bootstrap은 `bastion`, `kubernetes`, `platform` domain tag를 지원하고,
upgrade는 component별 고유 tag로 한 workflow만 선택한다. 전체 동시 upgrade target은
제공하지 않으며 운영자는 실제 경로를 직접 조합하지 않고 Make target을 사용한다.

## 검증 범위

```bash
make inventory
make syntax
make ssh-check
```

`make inventory`와 `make syntax`는 Inventory 해석과 Playbook 구문을 확인하는 정적 검증이다.
`make ssh-check`는 대상 노드에 실제 Ansible ping을 수행하지만 Kubernetes나 Argo CD 상태를
보장하지 않는다. bootstrap 또는 upgrade의 완료 판단은 해당 operation의 postcheck와
클러스터의 실제 workload 확인까지 포함해야 한다.

## 문서

- [아키텍처와 소유권](docs/architecture.md)
- [실행 방식과 artifact](docs/execution.md)
- [신규 Kubernetes 설치](docs/kubernetes-install.md)
- [Kubernetes 업그레이드](docs/kubernetes-upgrade.md)
- [Helm CLI 업그레이드](docs/helm-upgrade.md)
- [ArgoCD 업그레이드](docs/argocd-upgrade.md)
- [문제 해결](docs/troubleshooting.md)
- [스크립트 책임](scripts/README.md)
- [Secret 관리](../gitops/SECRETS.md)
