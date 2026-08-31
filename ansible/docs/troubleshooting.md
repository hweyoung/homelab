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

## Kubernetes 1.30.4에서 1.31.9 upgrade 장애 기록

이번 upgrade에서 확인한 장애와 해결 순서는 다음과 같다. 각 조치는 증상과 원인이 일치할
때만 사용하고, 다음 단계로 넘어가기 전에 cluster health를 다시 확인한다.

| 순서 | 증상 | 원인 | 해결 |
| --- | --- | --- | --- |
| 1 | `inventory_dir is undefined` | localhost validation에서 inventory 전용 변수를 project root 계산에 사용 | `ansible_config_file | dirname` 기준으로 project root 계산 |
| 2 | master의 `admin.conf`가 있는데 stat 결과가 없음 | localhost play의 local connection이 delegated task에도 적용 | play의 명시적 `connection: local` 제거 후 `delegate_to: k8s-master` 사용 |
| 3 | JSON loop가 built-in method를 받음 | `.items`가 JSON key가 아니라 dictionary method로 평가 | `(result.stdout | from_json)['items']` 사용 |
| 4 | 동일 version precheck 거부 | upgrade와 독립 postcheck의 목적이 다름 | 실제 upgrade는 더 높은 target만 허용하고 postcheck target에서만 동일 version 허용 |
| 5 | kubeadm health-check Job timeout | control plane은 drain되고 두 worker에는 사용자 정의 `NoSchedule` taint 존재 | control plane uncordon, dev taint 임시 제거 후 recovery upgrade |
| 6 | master system Pod `CreateContainerConfigError` | 1.31 kubelet이 1.30 API server에 지원되지 않는 `spec.clusterIP` selector 사용 | Pod 삭제 반복 대신 control plane upgrade 완료 |
| 7 | Kubespray task가 오랫동안 출력 없이 대기 | 상위 Ansible `command`가 하위 `ansible-playbook` 출력을 종료 시점까지 보관 | 별도 terminal에서 process와 run artifact의 `ansible.log` 확인 |
| 8 | prod worker drain이 6분 후 실패 | 단일 CNPG instance의 PDB가 eviction 차단 | maintenance window와 `reusePVC:true` 적용 후 worker별 제한 실행 |
| 9 | OpenBao가 `Running 0/1` | prod node 처리로 Pod가 재시작되며 sealed 상태가 됨 | 관리 terminal에서 대화형 unseal 후 Ready 확인 |

문제 해결 중 `--ignore-preflight-errors`, 강제 drain, PDB 직접 삭제, 전체 bootstrap 재실행을
일반적인 우회 수단으로 사용하지 않는다. 부분 upgrade 상태에서는 현재 API server, kubelet,
node schedulability와 stateful workload를 먼저 기록한다.

## 사전 Ansible 오류

### localhost에서 `inventory_dir`가 undefined

`inventory_dir`는 inventory host context에 의존하므로 localhost validation에서 project
root의 기본값으로 사용하지 않는다.

```text
{{ inventory_dir }}/../..: 'inventory_dir' is undefined
```

project root는 현재 Ansible configuration 위치를 기준으로 계산한다.

```yaml
ansible_project_root: "{{ ansible_config_file | dirname }}"
```

### delegated task가 localhost에서 실행됨

`/etc/kubernetes/admin.conf`가 master에 존재하는데 upgrade validation이 없다고 판단하면
ad-hoc stat으로 실제 host 상태를 먼저 확인한다.

```bash
./scripts/run-adhoc.sh k8s_master \
  --become \
  -m ansible.builtin.stat \
  -a 'path=/etc/kubernetes/admin.conf'
```

localhost play에 `connection: local`을 강제하면 `delegate_to` task의 연결까지 잘못 적용될
수 있다. implicit localhost local connection을 사용하고 cluster task만
`delegate_to: k8s-master`, `become: true`로 실행한다.

### JSON `items` loop 오류

다음 오류는 dictionary의 `items` method를 loop에 전달했을 때 발생한다.

```text
Invalid data passed to 'loop', it requires a list, got this instead:
<built-in method items of dict object>
```

JSON 배열 key는 bracket notation으로 접근한다.

```yaml
loop: "{{ (command_result.stdout | from_json)['items'] }}"
```

### 동일 version upgrade 거부

현재와 목표 version이 같으면 실제 upgrade 실행은 거부한다. 동일 version 검증은 독립
postcheck에서만 허용한다.

```bash
make kubernetes-upgrade-postcheck
```

### postcheck에서 worker `pool` label 누락

다음 오류는 worker의 실제 placement label과 inventory 계약이 다를 때 발생한다.

```text
Worker 필수 scheduling label 검증
'dict object' has no attribute 'pool'
```

postcheck는 누락 label을 `missing`으로 표시하도록 구현하며, 정상 upgrade 경로는 Kubespray
완료 후 홈랩 전용 `reconcile.yml`에서 label을 자동 복구한다. 이미 완료된 upgrade의 독립
postcheck에서 발견했다면 node-config를 한 번 재적용한 뒤 다시 검사한다.

```bash
make post-kubespray
make kubernetes-upgrade-postcheck
```

## Kubernetes upgrade health-check Job 스케줄 실패

### 증상

Kubespray upgrade가 첫 control plane의 `kubeadm upgrade apply` 단계에서 다음 오류로
중단될 수 있다.

```text
[ERROR CreateJob]: Job "upgrade-health-check-xxxxx" in the namespace
"kube-system" did not complete in 15s: no condition of type Complete
```

실패 후에는 다음과 같은 부분 업그레이드 상태가 나타날 수 있다.

- control plane node의 kubelet은 목표 version이지만 API server는 기존 version
- control plane node가 `Ready,SchedulingDisabled`
- CoreDNS 또는 dns-autoscaler가 `Pending`이나 `CreateContainerConfigError`
- `services have not yet been read at least once, cannot construct envvars` 이벤트
- master kubelet 로그에서 `spec.clusterIP is not a known field selector` 오류

`clusterDNS` 권장값이나 kubeadm configuration deprecation 메시지는 경고다. 실제 fatal
원인은 `upgrade-health-check` Job의 완료 실패 여부와 Pod 이벤트로 판단한다.

### 원인 확인

이 homelab은 단일 control plane을 사용하고 두 worker에 workload 분리용 `NoSchedule`
taint를 설정한다. Kubespray가 control plane을 drain하면 다음 조건이 동시에 발생할 수 있다.

```text
k8s-master      -> unschedulable
k8s-worker-dev  -> environment=dev:NoSchedule
k8s-worker-prod -> environment=prod:NoSchedule
```

이 상태에서는 kubeadm health-check Job을 실행할 node가 없다. 다음 명령으로 node와 이벤트를
확인한다.

```bash
kubectl get nodes -o wide
kubectl get nodes \
  -o custom-columns='NAME:.metadata.name,UNSCHEDULABLE:.spec.unschedulable,TAINTS:.spec.taints'
kubectl -n kube-system get jobs,pods -o wide \
  | grep -E 'upgrade-health-check|NAME'
kubectl -n kube-system get events \
  --sort-by=.metadata.creationTimestamp \
  | tail -n 100
```

다음 이벤트가 있으면 스케줄 가능한 node 부재가 원인이다.

```text
0/3 nodes are available: worker nodes had untolerated taint and the control plane
node was unschedulable
```

Kubespray가 kubelet binary를 먼저 갱신한 뒤 control plane 적용에 실패하면 kubelet과 API
server의 version도 함께 확인한다.

```bash
kubectl version
kubectl get nodes \
  -o custom-columns='NAME:.metadata.name,KUBELET:.status.nodeInfo.kubeletVersion'
./scripts/run-adhoc.sh k8s_master \
  --become \
  -m ansible.builtin.shell \
  -a "journalctl -u kubelet --since=-10min --no-pager | grep -E 'failed to list.*Service|spec.clusterIP' | tail -n 50"
```

다음 조합이면 kubelet 재시작이나 Pod 재생성으로 해결할 수 없는 부분 업그레이드 상태다.

```text
k8s-master kubelet: v1.31.x
kube-apiserver:     v1.30.x
failed to list *v1.Service: "spec.clusterIP" is not a known field selector
```

Kubernetes 1.31 kubelet은 Service informer에 `spec.clusterIP` field selector를 사용하지만
1.30 API server는 이를 지원하지 않는다. kubelet은 kube-apiserver보다 새 version이면 안
되므로 control plane upgrade를 완료해 지원되는 version 관계로 복구해야 한다.

### 복구

`--ignore-preflight-errors=CreateJob`로 우회하거나 전체 bootstrap을 실행하지 않는다. 실패한
upgrade의 artifact와 etcd backup을 보존한 상태에서 다음 순서로 복구한다.

1. Kubespray 실패로 cordon 상태에 남은 control plane을 복구한다.

   ```bash
   kubectl uncordon k8s-master
   kubectl wait --for=condition=Ready node/k8s-master --timeout=120s
   ```

2. upgrade health-check가 사용할 dev worker의 환경 taint를 임시 제거한다. prod worker의
   taint는 유지한다.

   ```bash
   kubectl taint node k8s-worker-dev \
     homelab.okbear.dev/environment=dev:NoSchedule-
   ```

3. API server readiness와 현재 version skew를 확인한다.

   ```bash
   kubectl get --raw='/readyz?verbose'
   kubectl version
   kubectl get nodes \
     -o custom-columns='NAME:.metadata.name,KUBELET:.status.nodeInfo.kubeletVersion,UNSCHEDULABLE:.spec.unschedulable,TAINTS:.spec.taints'
   ```

   API server가 기존 minor이고 master kubelet만 목표 minor라면 일반 precheck는
   `CreateContainerConfigError` Pod 때문에 실패한다. 스케줄 문제를 해소했고 API
   `/readyz`가 통과한 상태에서 upgrade 단계만 tag-scoped로 재개한다.

4. control plane upgrade를 완료한다.

   ```bash
   ./scripts/run-playbook.sh \
     kubernetes-upgrade-recovery \
     playbooks/kubernetes/upgrade.yml \
     --tags upgrade \
     -e kubernetes_upgrade_confirm=true
   ```

   이 명령은 장애로 통과할 수 없는 cluster health precheck만 생략한다. Kubespray
   `upgrade-cluster.yml`, 명시적 승인 gate와 version 검증은 그대로 수행한다. 수동
   `kubeadm upgrade apply`, `cluster.yml` 또는 `--ignore-preflight-errors=CreateJob`로
   우회하지 않는다.

5. API server가 목표 version으로 올라간 뒤 system Pod 복구를 확인한다.

   ```bash
   kubectl version
   kubectl -n kube-system rollout status deployment/coredns --timeout=180s
   kubectl -n kube-system rollout status deployment/dns-autoscaler --timeout=180s
   kubectl get --raw='/readyz?verbose'
   kubectl get nodes -o wide
   kubectl get pods -A \
     --field-selector=status.phase!=Running,status.phase!=Succeeded \
     -o wide
   ```

   master의 Calico, kube-proxy 또는 NodeLocalDNS가 version skew 해소 후에도 복구되지
   않으면 kubelet을 한 번 재시작한다.

   ```bash
   ./scripts/run-adhoc.sh k8s_master \
     --become \
     -m ansible.builtin.systemd_service \
     -a 'name=kubelet state=restarted'
   ```

   그래도 남은 실패 Pod는 `kubectl describe pod`로 동일 오류인지 확인한 뒤 Deployment나
   DaemonSet이 관리하는 Pod만 개별 재생성한다. static Pod, PVC 또는 stateful workload를
   이 절차로 삭제하지 않는다.

6. 전체 health와 upgrade 결과를 검증한다.

   ```bash
   make kubernetes-upgrade-postcheck
   kubectl -n kube-system get daemonsets
   kubectl get pods -A \
     --field-selector=status.phase!=Running,status.phase!=Succeeded \
     -o wide
   ```

dev worker의 임시 taint 제거 상태는 recovery upgrade와 postcheck가 끝날 때까지 유지한다.

### 업그레이드 완료 후 원상 복구

모든 node가 목표 version이고 postcheck가 성공한 뒤 dev worker의 taint를 복구한다.

```bash
kubectl taint node k8s-worker-dev \
  homelab.okbear.dev/environment=dev:NoSchedule \
  --overwrite
```

```bash
kubectl version
kubectl get nodes -o wide
kubectl get pods -A \
  --field-selector=status.phase!=Running,status.phase!=Succeeded \
  -o wide
kubectl get --raw='/readyz?verbose'
```

`NoSchedule` taint를 다시 추가해도 이미 dev worker에서 실행 중인 Pod는 자동 퇴거되지
않는다. 필요하면 업그레이드와 별개의 maintenance 작업으로 Pod 배치를 검토한다.

## Kubespray 실행 task에서 출력이 보이지 않음

다음 task에서 화면이 오래 멈춰 보여도 하위 Kubespray가 실행 중일 수 있다.

```text
TASK [kubespray : Kubespray upgrade-cluster.yml 실행]
```

현재 Role은 Kubespray `ansible-playbook` 전체를 상위 Ansible의 `command` task 하나로
실행한다. 하위 command가 끝날 때까지 stdout이 상위 task 결과로 반환되지 않으므로 별도
infra-bastion session에서 확인한다.

```bash
pgrep -af 'ansible-playbook.*upgrade-cluster.yml'
ps -eo pid,etime,stat,%cpu,%mem,cmd \
  | grep '[a]nsible-playbook.*upgrade-cluster.yml'
```

wrapper로 시작한 실행은 operation의 최신 artifact log를 확인한다.

```bash
RUN_DIR="$(ls -1dt runs/kubernetes-upgrade-recovery/* | head -n 1)"
tail -n 100 -f "$RUN_DIR/ansible.log"
```

process가 존재하고 log가 증가하면 중단하지 않는다. process가 사라졌는데 상위 task가
반환되지 않거나 log가 10분 이상 갱신되지 않을 때 마지막 task, SSH 연결과 대상 node
상태를 확인한다.

## Kubernetes worker drain이 CNPG PDB에 차단됨

### 증상

control plane upgrade 이후 worker 처리 중 단일 인스턴스 PostgreSQL Pod를 eviction하지
못하고 drain timeout이 발생할 수 있다.

```text
Cannot evict pod as it would violate the pod's disruption budget
error when evicting pods/"postgres-prod-1": global timeout reached
Failed to drain node k8s-worker-prod
```

Kubespray rescue가 성공하면 실패한 worker를 다시 schedulable 상태로 되돌린다. 다음 명령으로
node와 database가 정상 복구됐는지 먼저 확인한다.

```bash
kubectl get nodes -o wide
kubectl get cluster -A
kubectl get pdb -A
kubectl -n postgres-dev get pod -o wide
kubectl -n postgres-prod get pod -o wide
```

단일 CNPG instance의 PDB는 가용 database가 0개가 되는 drain을 의도적으로 차단한다.
`local-path` PVC는 다른 node로 이동할 수 없으므로 worker maintenance 동안 database
downtime을 수용하고 기존 PVC가 있는 node가 돌아오기를 기다려야 한다.

### 진행 조건

운영 데이터라면 검증된 CNPG backup과 복구 계획 없이 진행하지 않는다.

```bash
kubectl -n postgres-prod get backups.postgresql.cnpg.io
kubectl -n postgres-prod get scheduledbackups.postgresql.cnpg.io
```

초기 테스트 환경에서 데이터 손실과 downtime을 명시적으로 수용한 경우에는 backup을
생략할 수 있다. 이 결정이 PDB 강제 삭제나 `--force`, `--disable-eviction` 사용을 허용하는
것은 아니다.

### CNPG maintenance window 설정

정상 upgrade에서는 `make kubernetes-upgrade`가 이 절차를 자동 수행한다. 아래 수동 명령은
자동 cleanup이 실패했거나 live 상태를 진단해야 할 때만 사용한다.

dev와 prod Cluster에 maintenance window를 열고 기존 PVC 재사용을 지정한다.

```bash
kubectl -n postgres-dev patch cluster postgres-dev \
  --type merge \
  -p '{"spec":{"nodeMaintenanceWindow":{"inProgress":true,"reusePVC":true}}}'

kubectl -n postgres-prod patch cluster postgres-prod \
  --type merge \
  -p '{"spec":{"nodeMaintenanceWindow":{"inProgress":true,"reusePVC":true}}}'
```

긴 `custom-columns` 명령은 terminal wrapping으로 option이 분리될 수 있으므로 각 Cluster를
짧은 JSONPath로 확인한다.

```bash
kubectl -n postgres-dev get cluster postgres-dev \
  -o jsonpath='{.spec.nodeMaintenanceWindow}{"\n"}'
kubectl -n postgres-prod get cluster postgres-prod \
  -o jsonpath='{.spec.nodeMaintenanceWindow}{"\n"}'
kubectl get pdb -A
```

두 Cluster가 `inProgress:true`, `reusePVC:true`이고 CNPG PDB가 제거된 것을 확인한다.
ArgoCD가 live patch를 되돌리면 `gitops/databases/postgres/overlays/<environment>/`에 같은
설정을 선언하고 sync 완료 후 진행한다.

### worker별 upgrade 재개

control plane이 이미 목표 version이면 일반 신규 upgrade의 동일 version 방지 검증이 실행을
막는다. 공식 복구 경로는 홈랩 준비/cleanup과 postcheck를 포함하는 resume target이다.

```bash
make kubernetes-upgrade-resume
```

아래 직접 Kubespray 명령은 resume target 자체가 동작하지 않을 때 마지막 복구 수단으로만
사용한다. 명령은 `infra-bastion`에서 수행한다.

```bash
cd /home/rocky/homelab/ansible/kubespray
export ANSIBLE_CONFIG="$PWD/ansible.cfg"

../.kubespray-venv/bin/ansible-playbook \
  -i ../inventories/homelab/hosts.yml \
  playbooks/facts.yml \
  --become
```

Kubespray의 facts Playbook 경로는 repository root의 `facts.yml`이 아니라
`playbooks/facts.yml`이다.

dev worker를 먼저 처리하고 database와 workload 복구를 확인한다.

```bash
../.kubespray-venv/bin/ansible-playbook \
  -i ../inventories/homelab/hosts.yml \
  upgrade-cluster.yml \
  --become \
  -e kube_version=v1.31.9 \
  -e serial=1 \
  --limit k8s-worker-dev

kubectl get node k8s-worker-dev -o wide
kubectl -n postgres-dev get pod -o wide
```

dev가 정상일 때만 prod worker를 처리한다.

```bash
../.kubespray-venv/bin/ansible-playbook \
  -i ../inventories/homelab/hosts.yml \
  upgrade-cluster.yml \
  --become \
  -e kube_version=v1.31.9 \
  -e serial=1 \
  --limit k8s-worker-prod
```

Kubernetes와 Kubespray version이 달라지면 위 예시의 `kube_version`을 inventory에 승인된
목표 version으로 바꾼다.

### 사후 복구

prod drain으로 OpenBao Pod가 다시 시작되면 sealed 상태가 될 수 있다. key를 명령 인자,
로그 또는 artifact에 남기지 않고 관리 terminal에서 대화형으로 unseal한다.

```bash
kubectl -n openbao exec platform-openbao-0 -- bao status
kubectl -n openbao exec -it platform-openbao-0 -- bao operator unseal
```

모든 node, database와 OpenBao가 정상인 뒤 maintenance window를 닫는다.

```bash
kubectl -n postgres-dev patch cluster postgres-dev \
  --type merge \
  -p '{"spec":{"nodeMaintenanceWindow":{"inProgress":false,"reusePVC":true}}}'

kubectl -n postgres-prod patch cluster postgres-prod \
  --type merge \
  -p '{"spec":{"nodeMaintenanceWindow":{"inProgress":false,"reusePVC":true}}}'

kubectl taint node k8s-worker-dev \
  homelab.okbear.dev/environment=dev:NoSchedule \
  --overwrite

make kubernetes-upgrade-postcheck
```

`kubectl get pods`의 `STATUS=Running`만으로 완료를 판단하지 않는다. `Running 0/1` Pod도
장애 상태이므로 OpenBao, CNPG와 모든 container의 Ready 상태까지 확인한다.

## Kubernetes upgrade 최종 검증

모든 복구와 worker별 upgrade가 끝난 뒤 `infra-bastion`의 `ansible/`에서 postcheck를
실행한다.

```bash
make kubernetes-upgrade-postcheck
```

console에서는 version, node, API server와 비정상 Pod를 차례로 확인한다.

```bash
kubectl version
kubectl get nodes -o wide
kubectl wait --for=condition=Ready node --all --timeout=180s
kubectl get --raw='/readyz?verbose'
kubectl get apiservices
kubectl get pods -A -o wide
kubectl get pods -A \
  --field-selector=status.phase!=Running,status.phase!=Succeeded \
  -o wide
```

모든 node의 kubelet과 API server가 목표 version이어야 한다. phase filter는
`Running 0/1`을 찾지 못하므로 kube-system DaemonSet과 주요 stateful service를 별도로
검증한다.

```bash
kubectl -n kube-system get daemonsets
kubectl -n kube-system get deployments
kubectl get cluster -A
kubectl -n openbao get pod -o wide
kubectl -n openbao exec platform-openbao-0 -- bao status
kubectl -n argocd get applications.argoproj.io
```

다음 원상 복구도 확인한다.

- CNPG `nodeMaintenanceWindow.inProgress`가 `false`
- dev/prod 환경 taint가 inventory의 baseline과 일치
- OpenBao `Sealed=false`, Pod `Ready=1/1`
- CoreDNS, Calico, kube-proxy와 NodeLocalDNS의 desired 수와 ready 수 일치
- 예상하지 않은 최근 Warning event 없음

```bash
kubectl get pdb -A
kubectl get events -A \
  --field-selector=type=Warning \
  --sort-by=.metadata.creationTimestamp \
  | tail -n 100
```

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
