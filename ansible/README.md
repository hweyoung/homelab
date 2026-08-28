# Ansible — 홈랩 부트스트랩 자동화

이 디렉터리는 Terraform이 VM을 만든 뒤 Kubernetes와 ArgoCD를 부트스트랩하는 단계까지
소유한다. ArgoCD root Application이 적용된 이후의 platform과 application resource는
`gitops/`가 지속적으로 관리한다.

```text
Terraform (Mac)
    ↓ VM 생성
Ansible / Kubespray (infra-bastion)
    ↓ Kubernetes + ArgoCD bootstrap
ArgoCD / GitOps
    ↓ platform + application reconciliation
```

상세 책임과 노드 구조는 [architecture.md](docs/architecture.md)를 참고한다.

## 빠른 시작

모든 명령은 `infra-bastion`의 `ansible/` 디렉터리에서 실행한다.

```bash
./scripts/prepare-bastion.sh
cp secrets.yml.example secrets.yml
./scripts/run-vault.sh encrypt
make inventory
make syntax
```

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

## 공식 실행 인터페이스

Makefile을 운영 API로 사용한다.

| 명령 | 책임 | Vault |
| --- | --- | --- |
| `make bastion-ssh` | Bastion SSH, SELinux, firewalld | 불필요 |
| `make bastion-hosts` | Bastion `/etc/hosts` | 불필요 |
| `make tailscale` | Tailscale 설치 및 Tailnet join | 필요 |
| `make kubespray` | 신규 cluster `cluster.yml` 실행 | 불필요 |
| `make post-kubespray` | kubeconfig, node label, taint | 불필요 |
| `make helm` | Helm CLI 설치 | 불필요 |
| `make sops` | ArgoCD namespace SOPS age Secret | 필요 |
| `make argocd` | ArgoCD 설치와 root Application 적용 | 필요 |
| `make kubernetes-upgrade-precheck` | 기존 cluster upgrade 사전 점검 | 불필요 |
| `make kubernetes-upgrade` | 승인된 Kubernetes upgrade | 불필요 |
| `make kubernetes-upgrade-postcheck` | upgrade 사후 점검 | 불필요 |

점검 및 utility 명령:

```bash
make inventory
make syntax
make ssh-check
make vault
```

Kubernetes 신규 설치와 기존 cluster 업그레이드는 서로 다른 operation이다. 업그레이드에
`make kubespray` 또는 `kubespray_force=true`를 사용하지 않는다.

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
│   ├── site.yml                     # 전체 bootstrap 진입점
│   ├── bastion/
│   ├── network/
│   ├── kubernetes/                  # install, node-config, upgrade
│   └── platform/
├── roles/                           # 실제 검증과 상태 변경
│   ├── kubespray/                   # upstream checkout 검증과 실행
│   ├── kubernetes/                  # cluster version 및 health 검증
│   └── k8s_node_config/             # 설치 후 kubeconfig, label, taint
├── inventories/homelab/
├── scripts/
├── runs/                            # Git 비추적 execution artifact
└── docs/
```

`playbooks/site.yml`이 전체 bootstrap 진입점이며, 기존 cluster upgrade는
`playbooks/kubernetes/upgrade.yml`을 독립 진입점으로 사용한다. 운영자는 실제 경로를
직접 조합하지 않고 Make target을 사용한다.

## 문서

- [아키텍처와 소유권](docs/architecture.md)
- [실행 방식과 artifact](docs/execution.md)
- [신규 Kubernetes 설치](docs/kubernetes-install.md)
- [Kubernetes 업그레이드](docs/kubernetes-upgrade.md)
- [문제 해결](docs/troubleshooting.md)
- [스크립트 책임](scripts/README.md)
- [Secret 관리](../gitops/SECRETS.md)
