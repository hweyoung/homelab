# Kubernetes / Kubespray Upgrade Runbook

이미 설치된 cluster를 Kubespray `upgrade-cluster.yml`로 한 단계씩 업그레이드하는 절차다.

```text
신규 설치: playbooks/bootstrap.yml → kubespray/Kubernetes 검증 → cluster.yml
기존 upgrade: playbooks/upgrade.yml --tags kubernetes_upgrade_* → precheck → upgrade-cluster.yml → postcheck
```

`kubespray` Role은 upstream checkout과 실행만 담당하고, `kubernetes` Role은 cluster 상태와
version/health 검증만 담당한다. 실행 순서와 승인 gate는 upgrade Playbook이 명시한다.

## Ownership

Kubespray는 control plane, etcd, kubelet, container runtime, CNI, DNS와 metrics-server를
관리한다. ArgoCD는 cert-manager, Gateway, Traefik, CNPG, Secret operator와 application을
관리한다. ArgoCD 자체와 root Application은 Ansible bootstrap 소유다.

Kubespray의 내장 ArgoCD addon은 사용하지 않는다. nested Kubespray 실행에는
`argocd_enabled=false`와 Kubespray v2.28.1이 지원하는 `argocd_version=2.14.5`를 명시적으로
전달한다. 이 version은 실제 Ansible 관리 ArgoCD 목표 version과 무관하며, 비활성 addon의
download checksum 평가가 외부 `argocd_app_version`과 충돌하지 않게 하는 경계 값이다.

## Upgrade 경로

한 번에 하나의 Kubernetes minor만 올린다. 현재 minor의 최신 patch 적용 후 다음 minor로
이동한다. Kubespray release와 Kubernetes 지원 범위는 실행 시점의 upstream release notes로
확인한다.

```yaml
kubespray_version: "v2.x.y"
kube_version: "1.x.y"
```

`kubespray_version`은 Git tag이므로 선행 `v`가 필요하지만, Kubespray 내부
`kube_version`에는 선행 `v`를 붙이지 않는다.

Role은 동일 minor의 patch 상승 또는 바로 다음 minor만 허용하며 downgrade와 minor skip을
거부한다.

## Homelab 제약

이 cluster는 control plane과 각 worker가 한 대씩이며 `local-path` PV를 사용한다.

- local PV는 다른 node로 자동 이동하지 않는다.
- worker upgrade 중 stateful workload downtime이 발생할 수 있다.
- PDB, Stateful Pod 또는 PVC를 자동 강제 삭제하지 않는다.
- `serial=1`로 node를 순차 처리한다.
- PostgreSQL과 OpenBao backup을 VM snapshot으로 대체하지 않는다.

CNPG maintenance가 필요하면 backup 이후 별도 GitOps 변경으로 검토한다.

```yaml
spec:
  nodeMaintenanceWindow:
    inProgress: true
    reusePVC: true
```

Upgrade Role은 이 설정을 자동 적용하지 않는다.

## 사전 체크리스트

- [ ] GitOps 변경 freeze
- [ ] Kubespray release notes와 Kubernetes 지원 범위 확인
- [ ] 모든 Node Ready
- [ ] API server `/readyz` 정상
- [ ] control-plane 및 `kube-system` Pod 정상
- [ ] APIService 정상
- [ ] etcd health 확인 및 snapshot 생성
- [ ] PostgreSQL dev/prod backup 완료
- [ ] OpenBao backup 완료
- [ ] PV/PVC와 local PV node 매핑 기록
- [ ] PDB 및 CNPG maintenance 계획 확인
- [ ] Node label/taint 기록
- [ ] ArgoCD Application 상태 기록
- [ ] removed/deprecated API 검토
- [ ] 필요하면 추가 보호 수단으로 VM snapshot 생성

API 후보 검색 결과를 일괄 치환하지 않고 target release의 API lifecycle을 각각 확인한다.

```bash
rg -n 'flowcontrol.apiserver.k8s.io/v1beta3' ../gitops
rg -n 'apiVersion:.*(v1alpha|v1beta)' ../gitops
```

## 실행

모든 명령은 `infra-bastion`의 `ansible/` 디렉터리에서 실행한다.

```bash
make sync-kubespray
make kubernetes-upgrade-precheck
```

precheck의 Node, Pod, PDB, PV/PVC와 deprecated API 후보를 사람이 검토하고 backup 완료를
확인한 후 실행한다.

```bash
make kubernetes-upgrade
```

Make target은 `kubernetes_upgrade_confirm=true`를 전달한다. 사후 점검만 다시 수행할 수
있다.

```bash
make kubernetes-upgrade-postcheck
```

독립 사후 점검 target만 `kubernetes_upgrade_postcheck_only=true`를 전달하여 현재 version과
목표 version이 같은 상태를 허용한다. 전체 upgrade target은 동일 version 실행을 거부한다.

업그레이드 목적으로 `kubespray_force=true` 또는 `cluster.yml`을 실행하지 않는다.

## Upgrade 중 원칙

- GitOps 변경 freeze 유지
- Kubernetes와 application/component version 변경을 동시에 수행하지 않음
- dev worker 처리 중 ArgoCD reconciliation 일시 중단 가능성 수용
- prod worker 처리 전 stateful workload downtime 공지
- PDB, maintenance mode, Pod와 PVC를 자동 우회하지 않음
- Secret, token, kubeconfig와 database credential을 로그에 출력하지 않음

## 사후 체크리스트

- [ ] 모든 Node Ready 및 kubelet target version 일치
- [ ] API server와 APIService 정상
- [ ] CoreDNS, NodeLocalDNS, CNI와 metrics-server 정상
- [ ] Node label/taint 유지
- [ ] ArgoCD와 Application Synced/Healthy
- [ ] PostgreSQL dev/prod 정상
- [ ] OpenBao unseal 및 Ready
- [ ] ESO, SecretStore와 ExternalSecret Ready
- [ ] cert-manager, Traefik과 Cloudflare Tunnel 정상
- [ ] Gateway와 HTTPRoute 정상
- [ ] dev/prod application 정상
- [ ] GitOps freeze 해제

```bash
kubectl get nodes -o wide
kubectl get pods -A
kubectl get apiservices
kubectl get --raw='/readyz?verbose'
kubectl get clusters.postgresql.cnpg.io -A
kubectl get externalsecret,secretstore -A
kubectl get gateway,httproute -A
```

DNS 실동작 확인은 임시 Pod를 생성하므로 운영자가 승인해 수동 수행한다.

## 실패와 복구

실패하면 다음 minor로 진행하지 않는다. 해당 Run Directory의 `summary.md`, `stdout.log`와
metadata를 보존하고 실패한 node 및 control plane 상태를 확인한다.

선택한 Kubespray release의 recovery 절차를 따른다. 데이터 손상이 의심되면 etcd,
PostgreSQL과 OpenBao 각각의 검증된 backup을 사용한다. local-path PVC를 다른 node에 임의로
연결하거나 신규 PVC로 대체하지 않는다.
