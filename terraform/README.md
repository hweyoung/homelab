# Terraform — Proxmox VM 프로비저닝

단일 Proxmox 노드에 Rocky Linux 기반 홈랩 VM 4대를 생성합니다. Terraform은 Mac에서
실행하며 VM의 compute, disk, network와 cloud-init 입력까지만 소유합니다. OS 구성,
Kubernetes 설치와 클러스터 리소스는 각각 Ansible/Kubespray와 Argo CD에 위임합니다.

> 이 문서는 `2026-09-08` 현재 저장소의 선언을 기준으로 합니다. 실제 Proxmox 상태를
> 조회한 결과는 아닙니다.

## 구성 전략

```text
Mac / Terraform
└── Proxmox VM lifecycle
    └── infra-bastion / Ansible·Kubespray
        └── Kubernetes / Argo CD
```

- `for_each = var.vms`로 VM별 차이는 입력값에 두고 리소스 정의는 하나로 유지합니다.
- Rocky Linux cloud-init 템플릿을 full clone해 동일한 OS 기준점을 사용합니다.
- Kubernetes 노드 주소가 바뀌지 않도록 정적 IP를 기본값으로 사용합니다.
- API token, SSH key와 환경별 주소는 `terraform.tfvars`로 분리합니다.
- Kubernetes 리소스를 Terraform state에 넣지 않아 GitOps와 소유권이 겹치지 않게 합니다.

## VM 구성

| VM | vCPU | RAM | Disk | 기본 IP | 역할 |
| --- | ---: | ---: | ---: | --- | --- |
| `infra-bastion` | 2 | 6GiB | 40GiB | `192.168.0.10/24` | Ansible/Kubespray 실행점 |
| `k8s-master` | 2 | 8GiB | 80GiB | `192.168.0.11/24` | Control Plane, etcd |
| `k8s-worker-prod` | 4 | 24GiB | 400GiB | `192.168.0.12/24` | prod, stable platform |
| `k8s-worker-dev` | 4 | 20GiB | 300GiB | `192.168.0.13/24` | dev, mutable platform |

VM은 하나의 Proxmox 호스트에 배치되므로 물리 장애 격리나 고가용성을 제공하지 않습니다.

## 디렉터리 구성

핵심 파일만 표시합니다.

```text
terraform/
├── provider.tf              # Proxmox 연결
├── variables.tf             # VM과 네트워크 입력
├── main.tf                  # VM 리소스
├── outputs.tf               # VM과 inventory 출력
└── terraform.tfvars.example # 입력 예시
```

## 사전 준비

### Proxmox API token

최소 권한의 Terraform 전용 사용자와 API token을 준비합니다. 아래 예시는 Datacenter 전체에
`PVEVMAdmin`을 부여하므로 실제 환경에서는 가능한 범위로 축소합니다.

```bash
pveum user add terraform@pve
pveum user token add terraform@pve tf --privsep 0
pveum aclmod / -user terraform@pve -role PVEVMAdmin
```

token secret은 생성 시 한 번만 표시됩니다. `terraform.tfvars`에 저장하되 Git에 커밋하지
않습니다.

### Rocky Linux cloud-init template

기본값은 Proxmox의 `Rocky-9-Template`입니다. 템플릿에는 다음 항목이 필요합니다.

- cloud-init drive(`ide2`)
- `virtio` network와 `virtio-scsi-pci` disk 지원
- SSH 접속 가능한 Rocky Linux cloud image
- `qemu_agent = 1`을 사용할 경우 설치·활성화된 QEMU Guest Agent

템플릿 이름, storage와 bridge가 다르면 `terraform.tfvars`에서 변경합니다.

## 입력값

```bash
cp terraform.tfvars.example terraform.tfvars
```

주요 입력은 다음과 같습니다.

| 변수 | 용도 |
| --- | --- |
| `pm_api_url` | Proxmox API endpoint |
| `pm_api_token_id` | `user@realm!token` 형식의 token ID |
| `pm_api_token_secret` | 민감한 token secret |
| `target_node` / `storage` | VM을 배치할 Proxmox node와 storage |
| `network_bridge` | VM network bridge |
| `gateway` / `nameserver` | cloud-init network 설정 |
| `ci_user` / `ssh_public_key` | 초기 SSH 사용자와 공개키 |
| `vms` | VM별 VMID, CPU, memory, disk, IP와 tag |

`pm_tls_insecure`의 기본값은 self-signed 인증서를 고려한 `true`입니다. 신뢰할 수 있는
인증서를 구성한 환경에서는 `false`로 변경합니다.

## 실행

모든 명령은 Mac의 `terraform/` 디렉터리에서 실행합니다.

```bash
terraform init
terraform fmt -check
terraform validate
terraform plan
terraform apply
```

변경 전에는 `plan`에서 VM 교체와 disk/network 변경 여부를 확인합니다. 특히 VM 삭제나
교체가 포함된 plan은 PVC와 데이터 복구 계획을 먼저 확인한 뒤 적용합니다.

## Ansible handoff

적용 후 생성된 VM 정보는 다음 출력에서 확인합니다.

```bash
terraform output vms
terraform output -raw ansible_inventory
```

현재 `ansible_inventory` 출력은 Bastion 이름을 `bastion`으로 찾지만 기본 VM 이름은
`infra-bastion`이므로 해당 그룹이 비어 있을 수 있습니다. 자동 생성 결과를 바로 사용하지
말고 [`../ansible/inventories/homelab/`](../ansible/inventories/homelab/)과 대조해야 합니다.
Terraform 적용 이후의 SSH, Tailscale, Kubernetes와 Argo CD 작업은 `ansible/`에서
수행합니다.

## State와 Secret

- `terraform.tfvars`와 `terraform.tfstate*`는 Git에 커밋하지 않습니다.
- `sensitive = true`는 CLI 출력을 가릴 뿐 state의 값을 암호화하지 않습니다.
- state에는 Proxmox token 등 민감값이 포함될 수 있으므로 접근 권한과 backup을 별도로
  관리합니다.
- 여러 운영자가 함께 사용할 경우 locking과 encryption을 제공하는 remote backend를
  검토합니다.

## 운영상 주의사항

- `qemu_agent`는 템플릿에 Guest Agent가 준비된 경우에만 활성화합니다.
- `lifecycle.ignore_changes`가 network 변경을 무시하므로 의도한 network 변경은 plan과
  실제 Proxmox 설정을 함께 확인합니다.
- 기본 CPU 설정은 현재 Provider 호환성을 위해 core 수만 지정합니다.
- 정적 IP를 바꾸면 Ansible inventory와 클러스터의 기존 노드 주소도 함께 검토합니다.
- 이 디렉터리의 검증은 Terraform 선언에 대한 정적 검증이며 실제 VM health를 보장하지
  않습니다.

다음 단계는 [Ansible/Kubespray 운영](../ansible/README.md)에서 이어집니다.
