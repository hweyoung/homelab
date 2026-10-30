# Ansible 아키텍처와 소유권

## 전체 책임 흐름

```text
┌──────────────────┐
│ Terraform on Mac │
│ VM과 기반 자원   │
└────────┬─────────┘
         │ 생성된 host/IP
         ▼
┌────────────────────────────┐
│ Ansible on infra-bastion    │
│ Tailscale, Kubespray, Helm  │
│ ArgoCD + root Application   │
└────────────┬───────────────┘
             │ bootstrap handoff
             ▼
┌────────────────────────────┐
│ ArgoCD / gitops/            │
│ platform 및 application     │
│ 지속 reconciliation         │
└────────────────────────────┘
```

Terraform은 Mac에서 실행한다. Ansible과 Kubespray는 `infra-bastion`에서 실행한다. ArgoCD
bootstrap 이후에는 기존 GitOps owner가 platform 및 application resource의 권위 있는
소스다.

## 노드 역할

| Host | 책임 |
| --- | --- |
| `infra-bastion` | Ansible controller, Kubespray checkout/runtime, Tailscale subnet router |
| `k8s-master` | Kubernetes control plane과 etcd |
| `k8s-worker-prod` | prod workload, stable platform, prod stateful workload |
| `k8s-worker-dev` | dev workload, mutable platform, ArgoCD와 개발 관측 도구 |

Inventory는 이 이름을 그대로 사용한다. Kubespray 호환을 위해 `kube_control_plane`,
`kube_node`, `etcd`, `k8s_cluster` group도 유지한다.

```text
tailscale_nodes
└── bastion
    └── infra-bastion

k8s_cluster
├── kube_control_plane
│   └── k8s-master
└── kube_node
    ├── k8s-worker-prod
    └── k8s-worker-dev
```

## Ansible이 소유하는 것

- Bastion SSH, SELinux와 firewalld
- Bastion `/etc/hosts`
- Tailscale 설치와 join
- Kubespray 신규 설치 및 기존 cluster upgrade wrapper
- kubeconfig, node label과 prod taint
- ArgoCD bootstrap용 Helm CLI
- ArgoCD namespace prerequisite와 SOPS age Secret
- 선택적인 private repository credential
- ArgoCD Helm 설치와 root Application 적용

## GitOps에 위임하는 것

- namespace, RBAC, NetworkPolicy, ResourceQuota, LimitRange, PSA
- Gateway API, Traefik, cert-manager와 Cloudflare Tunnel
- MinIO, CloudNativePG와 application database
- Prometheus, Grafana, Loki와 Alloy
- application deployment와 지속적인 drift reconciliation

새 resource가 한 번만 필요한 bootstrap인지, 지속적인 reconciliation이 필요한지 먼저
판단한다. 후자라면 Ansible Role에 추가하지 않고 기존 `gitops/` owner에 배치한다.

## 코드 호출 구조

```text
Makefile
  ├── controller/read-only helper
  │   ├── prepare-bastion.sh
  │   ├── sync-kubespray.sh
  │   ├── run-inventory.sh
  │   └── run-ansible.sh --syntax-check
  └── operational Playbook
      └── run-playbook.sh
          └── playbooks/
              └── roles/
```

역할별 Playbook은 대상 host, `become`, environment, 실행 순서와 tag를 정의한다. Role은
재사용 가능한 작업 명세만 소유한다.

```text
playbooks/kubernetes/install.yml
  ├── kubespray: checkout/entrypoint 검증
  ├── kubernetes: target version과 기존 cluster 상태 확인
  ├── kubernetes: install 사전 점검
  ├── kubespray: cluster.yml 실행
  └── kubernetes: install 사후 점검

playbooks/upgrade.yml → kubernetes/upgrade.yml
  ├── kubespray: checkout/entrypoint 검증
  ├── kubernetes: upgrade path 검증과 precheck
  ├── playbook: 명시적 승인 gate
  ├── kubespray: upgrade-cluster.yml 실행
  └── kubernetes: postcheck
```

`kubespray` Role에는 upstream Kubespray 실행 환경과 명령만 두고, `kubernetes` Role에는
cluster version, health, PDB/PV 및 사후 상태 검증만 둔다. 전체 lifecycle의 순서는
Playbook이 소유한다.

`kubernetes` Role의 task는 lifecycle별 디렉터리로 구분한다. 파일은 독립적인 작업 명세이며
디렉터리 자체가 실행 순서를 결정하지 않는다.

```text
roles/kubernetes/tasks/
├── validate/
│   └── version.yml
├── install/
│   ├── state.yml
│   ├── precheck.yml
│   └── postcheck.yml
└── upgrade/
    ├── validate.yml
    ├── health.yml
    ├── precheck.yml
    └── postcheck.yml
```

같은 규칙을 나머지 영역에도 적용한다.

| Playbook | 명시하는 절차 | Role 작업 명세 |
| --- | --- | --- |
| `bastion/ssh.yml` | configure → SELinux → firewall | `bastion_ssh` |
| `bastion/hosts.yml` | hostname mapping 관리 | `bastion_hosts` |
| `network/tailscale.yml` | install → forwarding → join | `tailscale` |
| `kubernetes/node-config.yml` | validate → kubeconfig → labels → taints | `k8s_node_config` |
| `platform/helm/install.yml` | Helm CLI 최초 install | `helm/tasks/install.yml` |
| `platform/helm/upgrade.yml` | validate → precheck → approved binary replacement → postcheck | `helm/tasks/upgrade/` |
| `platform/argocd/install.yml` | validate → prerequisite → Secret → precheck → deploy → root app → postcheck | `argocd` common tasks (`argocd_operation=bootstrap`) |
| `platform/argocd/upgrade.yml` | validate → precheck → approved deploy → postcheck | `argocd` common tasks (`argocd_operation=upgrade`) |

Role의 `tasks/`에는 위 표의 개별 작업 파일만 둔다. 실행 순서를 숨기는 `tasks/main.yml`은
사용하지 않는다. 단, Ansible handler 진입점인 `handlers/main.yml`은 규약에 따라 유지한다.

root `bootstrap.yml`은 최초 구성 Playbook을 순서대로 직접 import하며 부분 실행은 domain
tag를 사용한다. root `upgrade.yml`은 Kubernetes, Helm과 ArgoCD upgrade Playbook을 등록하되
component별 고유 tag로 하나만 선택한다. 영역별 wrapper와 전체 동시 upgrade target은 두지
않는다.

## Runtime과 비추적 파일

다음은 controller local state이며 Git으로 관리하지 않는다.

```text
.ansible/
.venv/
.kubespray-venv/
kubespray/
runs/*
secrets.yml
inventories/homelab/hosts.yml
```
