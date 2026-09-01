# Kubernetes / Kubespray 문제 해결

이 문서는 기존 Kubernetes 클러스터 업그레이드 문제를 실행 phase별로 분류한다. 명령은
별도 언급이 없으면 `infra-bastion`의 `/home/rocky/homelab/ansible`에서 실행한다.

```text
Phase 0 기준 확인
  -> Phase 1 Kubespray 준비
  -> Phase 2 upgrade precheck
  -> Phase 3 upgrade 실행
  -> Phase 4 중단 상태 분류 및 복구
  -> Phase 5 upgrade postcheck
  -> Phase 6 artifact 분석
```

## 공통 안전 원칙

- bootstrap playbook으로 기존 클러스터를 다시 만들지 않는다.
- 원인을 확인하기 전에 강제 drain, PDB 삭제, Pod 강제 삭제를 하지 않는다.
- `--ignore-preflight-errors=all` 또는 수동 `kubeadm upgrade`로 검증을 우회하지 않는다.
- 클러스터 조회는 `k8s-master:/etc/kubernetes/admin.conf`를 기준으로 한다.
- Vault, SOPS, kubeconfig 및 credential 원문은 artifact나 이슈에 첨부하지 않는다.
- wrapper가 남긴 cleanup 결과까지 확인한 뒤 재실행한다.

## Phase 0. 실행 전 기준 확인

### 저장소와 Ansible 진입점

```bash
pwd
git status --short
git log -1 --oneline
make inventory
make syntax
```

예상 기준은 다음과 같다.

- 작업 디렉터리: `/home/rocky/homelab/ansible`
- inventory: `inventories/homelab/hosts.yml`
- upgrade 진입점: `playbooks/kubernetes/upgrade.yml`
- Kubespray 실행 playbook: `kubespray/upgrade-cluster.yml`

dirty worktree라면 변경 출처를 확인한다. 특히 `kubespray/` 하위 변경은 checkout 실패와
후속 실행 결과를 왜곡할 수 있다.

### 버전 변수 계약

```bash
rg -n "kubespray_version|kube_version|kubespray_argocd|helm_cli_version|argocd_app_version" \
  inventories/homelab/group_vars/all.yml
```

현재 변수 형식은 다음 경계를 지켜야 한다.

| 변수 | 형식 | 소유 범위 |
| --- | --- | --- |
| `kubespray_version` | `v2.28.1` | Git tag checkout |
| `kube_version` | `1.32.8` | Kubespray Kubernetes version |
| `kubespray_argocd_enabled` | `false` | Kubespray addon 차단 |
| `kubespray_argocd_version` | `2.14.5` | Kubespray 내부 checksum 호환값 |
| `helm_cli_version` | `v3.19.5` | homelab Helm role |
| `argocd_app_version` | `3.0.0` | homelab ArgoCD role |

Kubespray 검증과 충돌하므로 inventory에 전역 `helm_version` 또는 `argocd_version`을
정의하지 않는다. Kubernetes 버전에도 선행 `v`를 붙이지 않는다.

### 대상 inventory와 cluster 확인

```bash
./scripts/run-inventory.sh --graph
./scripts/run-inventory.sh --list >/dev/null
ssh k8s-master 'sudo KUBECONFIG=/etc/kubernetes/admin.conf kubectl config current-context'
ssh k8s-master 'sudo KUBECONFIG=/etc/kubernetes/admin.conf kubectl get nodes -o wide'
```

`kube_control_plane`, `kube_node`, `etcd`, `k8s_cluster` 그룹과 실제 node 이름이 일치해야
한다. inventory 원문에는 IP와 사용자가 있으므로 외부에 그대로 공유하지 않는다.

## Phase 1. Kubespray checkout 및 실행 환경 준비

```bash
make sync-kubespray
git -C kubespray describe --tags --exact-match
test -x .kubespray-venv/bin/ansible-playbook
.kubespray-venv/bin/ansible-playbook --version
```

확인 항목:

- checkout tag가 `kubespray_version`과 일치한다.
- `kubespray/upgrade-cluster.yml`, `kubespray/ansible.cfg`, `kubespray/roles/`가 존재한다.
- `.kubespray-venv`는 프로젝트 `.venv`와 분리되어 있다.
- Kubespray 요구 범위의 Ansible/Jinja/netaddr가 설치되어 있다.

### `pathspec '2.28.1' did not match`

`kubespray_version`에서 `v`가 빠졌거나 local clone에 tag가 없을 때 발생한다.

```bash
rg -n "kubespray_version" inventories/homelab/group_vars/all.yml
git -C kubespray tag -l 'v2.28.1'
git -C kubespray status --short
```

변수는 `v2.28.1`처럼 실제 Git tag와 동일해야 한다. tag가 없다면 remote/tag fetch 상태를
확인하고, `kubespray/`에 보존해야 할 로컬 변경이 없는지 먼저 확인한다.

## Phase 2. Kubernetes upgrade precheck

```bash
make kubernetes-upgrade-precheck
```

precheck는 대략 다음 순서로 실패를 차단한다.

1. Kubespray checkout, venv, inventory 경로 검증
2. 현재/목표 Kubernetes 버전과 upgrade 경로 검증
3. node Ready, API `/readyz`, system Pod 상태 검증
4. PDB와 stateful workload의 drain 위험 검증
5. upgrade 승인 변수 검증

Worker scheduling label은 inventory의 desired state와 일치해야 한다. 누락된 label을
잘못된 baseline으로 인정하지 않고 precheck에서 차단한다. prod taint 자체는
precheck/postcheck assertion 대상에서 제외하고 upgrade cleanup과 운영 확인으로 관리한다.
다음 명령으로 node 구성을 수렴시킬 수 있다.

```bash
make post-kubespray
```

canonical prod taint는 GitOps workload toleration과 동일한
`homelab.okbear.dev/environment=prod:NoSchedule`이다. 이전 `pool=prod:NoSchedule` taint가
남았다면 workload가 이를 toleration하지 못하므로 제거하고 node-config role로 수렴시킨다.

### `not kube_version.startswith('v')`

Kubespray 2.28 계열은 정규화된 Kubernetes 버전을 요구한다.

```yaml
kube_version: "1.32.8"
```

CLI의 extra vars도 동일하다. `-e kube_version=v1.32.8`이 아니라
`-e kube_version=1.32.8`이어야 한다.

### `not helm_version.startswith('v')`

homelab의 Helm 버전을 Kubespray 전역 변수 `helm_version`으로 전달한 경우다. inventory의
homelab 변수는 `helm_cli_version`을 사용하고, Kubespray에는 불필요한 Helm 변수를 넘기지
않는다.

```bash
rg -n "(^|[[:space:]])helm_version:" inventories playbooks roles
rg -n "helm_cli_version" inventories playbooks roles
```

### `argocd_install_checksums... has no attribute '3.0.0'`

Kubespray download role가 homelab의 `argocd_app_version: 3.0.0`을 addon 버전으로 잘못
해석한 경우다. Kubespray 호출에는 addon 경계를 명시한다.

```yaml
argocd_enabled: false
argocd_version: "2.14.5"
```

`argocd_enabled=false`라도 Kubespray가 download dictionary를 template하는 과정에서
checksum lookup이 먼저 평가될 수 있으므로 호환되는 내부 버전도 함께 전달한다.

### node/API/Pod health 실패

```bash
ssh k8s-master 'sudo KUBECONFIG=/etc/kubernetes/admin.conf kubectl get nodes'
ssh k8s-master 'sudo KUBECONFIG=/etc/kubernetes/admin.conf kubectl get --raw=/readyz?verbose'
ssh k8s-master 'sudo KUBECONFIG=/etc/kubernetes/admin.conf kubectl get pods -A -o wide'
```

`Running`은 Ready를 의미하지 않는다. `READY=0/1`, CrashLoopBackOff, Pending Pod도 실패
대상이다. node의 `SchedulingDisabled`가 이전 실패에서 남았는지도 확인한다.

### PDB 또는 local-path workload 실패

```bash
ssh k8s-master 'sudo KUBECONFIG=/etc/kubernetes/admin.conf kubectl get pdb -A'
ssh k8s-master 'sudo KUBECONFIG=/etc/kubernetes/admin.conf kubectl get pod -A \
  -o custom-columns=NS:.metadata.namespace,NAME:.metadata.name,NODE:.spec.nodeName,READY:.status.containerStatuses[*].ready'
```

single replica와 `local-path` 조합은 node 이동이 불가능할 수 있다. workload를 강제로
삭제하거나 CNPG PDB를 제거하지 말고, 어느 node에 저장소와 Pod가 묶여 있는지 먼저
확인한다.

## Phase 3. Kubespray upgrade 실행

```bash
make kubernetes-upgrade
```

정상 호출은 Kubespray `upgrade-cluster.yml`에 다음 경계를 **타입을 보존하여** 전달한다.

- `kube_version=1.32.8`
- `serial=1`
- `argocd_enabled=false` (문자열이 아닌 boolean)
- `argocd_version=2.14.5`

`ansible-playbook -e argocd_enabled=false`처럼 key/value 형식으로 넘기면 nested Ansible에서
`"false"` 문자열이 될 수 있다. Kubespray의 addon 조건이 `when: argocd_enabled`처럼 bare
variable을 사용하면 이 문자열이 truthy로 평가되어 addon이 실행될 수 있다. JSON extra-vars
등으로 boolean 타입을 보존하거나, addon을 사용하지 않을 때 해당 변수를 CLI에서 넘기지
않고 Kubespray 기본값을 사용해야 한다.

upgrade는 node를 한 번에 하나씩 처리한다. 실패했다고 곧바로 전체 명령을 반복하지 말고
Phase 4에서 실제 변경 범위를 먼저 확인한다.

Kubespray 실행 직전에는 prod custom taint만 임시 제거된다. placement label과
control-plane taint는 유지한다. Kubespray가 실패해도 Ansible `always`가
`homelab.okbear.dev/environment=prod:NoSchedule`을 복원한다. 프로세스 강제 종료 등으로
cleanup이 실행되지 않았다면 다음 precheck가 missing taint를 명확하게 차단한다.

### 화면 출력이 멈춘 것처럼 보이는 경우

Kubespray subprocess 출력이 wrapper에 의해 모였다가 task 종료 시 보일 수 있다. 별도
세션에서 최신 artifact를 확인한다.

```bash
run_id="$(ls -1t runs/kubernetes-upgrade | head -1)"
tail -f "runs/kubernetes-upgrade/${run_id}/stdout.log"
```

프로세스 존재 여부, `metadata.yml`의 종료 상태, 대상 node의 kubelet/API 상태를 함께 본다.

### download preparation 단계 실패

긴 `downloads` dictionary는 원인이라기보다 template 평가 결과다. 메시지의 마지막
undefined variable 또는 checksum key를 찾는다.

```bash
rg -n "undefined|has no attribute|checksum|FAILED" \
  "runs/kubernetes-upgrade/${run_id}/stdout.log"
```

최근 대표 원인은 ArgoCD addon 변수 충돌이다. Kubespray source를 직접 수정하기보다
inventory 변수 경계와 nested playbook extra vars를 먼저 확인한다.

## Phase 4. 중단 상태 분류 및 복구

먼저 실패 시점을 둘로 나눈다.

### Kubernetes 변경 전 실패

inventory validation, download preparation 등에서 종료되었고 모든 node 버전이 기존
버전이라면 변수나 checkout을 수정한 뒤 Phase 2부터 다시 수행한다.

### 일부 node만 upgrade된 실패

```bash
ssh k8s-master 'sudo KUBECONFIG=/etc/kubernetes/admin.conf kubectl get nodes \
  -o custom-columns=NAME:.metadata.name,VERSION:.status.nodeInfo.kubeletVersion,UNSCHEDULABLE:.spec.unschedulable'
ssh k8s-master 'sudo KUBECONFIG=/etc/kubernetes/admin.conf kubectl get pods -A -o wide'
```

다음을 확인한다.

- 어느 node까지 목표 버전이 적용됐는가
- `SchedulingDisabled` 또는 maintenance label/taint가 남았는가
- system Pod와 stateful workload가 Ready인가
- wrapper의 `always` cleanup이 수행됐는가

상태가 안전하면 동일한 `make kubernetes-upgrade` workflow를 재실행한다. 직접 Kubespray를
호출하는 복구는 자동 경로의 차단 원인을 확인한 뒤 마지막 수단으로만 사용한다.

```bash
cd /home/rocky/homelab/ansible/kubespray
export ANSIBLE_CONFIG="$PWD/ansible.cfg"
../.kubespray-venv/bin/ansible-playbook \
  -i ../inventories/homelab/hosts.yml \
  upgrade-cluster.yml \
  --become \
  -e kube_version=1.32.8 \
  -e serial=1 \
  -e argocd_enabled=false \
  -e argocd_version=2.14.5 \
  --limit <확인된-node>
```

`--limit`은 버전과 상태를 확인한 정확한 node에만 사용한다. 추측한 node 이름이나 전체
worker group을 넣지 않는다.

### `ERROR CreateJob`: `upgrade-health-check`가 15초 안에 완료되지 않는 경우

대표 로그:

```text
[ERROR CreateJob]: Job "upgrade-health-check-..." in the namespace "kube-system"
did not complete in 15s: no condition of type Complete
```

이 오류는 kubeadm이 cluster health를 확인하려고 만든 임시 Job이 `Complete`가 되지 않은
것이다. YAML kind deprecation과 `clusterDNS=169.254.25.10` 메시지는 warning이며 이
실패의 직접 원인이 아니다. `--ignore-preflight-errors`로 우회하지 않는다.

Kubespray가 first control-plane을 먼저 drain한 single-control-plane 구성에서는 해당 node가
다음처럼 남을 수 있다.

```text
k8s-master  Ready,SchedulingDisabled
```

다만 worker가 Ready인 환경에서는 cordon만으로 원인을 단정할 수 없다. health-check Pod의
Pending, image pull, admission, CNI 또는 scheduler event를 함께 확인한다. 임시 Job은 kubeadm
종료 시 삭제될 수 있으므로 실패 직후 event와 scheduler 로그가 중요하다.

```bash
sudo KUBECONFIG=/etc/kubernetes/admin.conf kubectl -n kube-system get events \
  --sort-by=.lastTimestamp | tail -n 80
sudo KUBECONFIG=/etc/kubernetes/admin.conf kubectl -n kube-system get pod \
  -o wide | grep upgrade-health-check || true
sudo KUBECONFIG=/etc/kubernetes/admin.conf kubectl -n kube-system logs \
  -l component=kube-scheduler --tail=200
```

event를 기준으로 실패 유형을 구분한다.

| event | 의미 | 다음 확인 |
| --- | --- | --- |
| `FailedScheduling`, `unschedulable` | health-check Pod를 배치하지 못함 | cordon, taint, scheduler |
| `Scheduled`, `Pulled`, `Started` 후 `DeadlineExceeded` | Pod는 실행됐지만 제한 시간 안에 Job 완료 조건이 생기지 않음 | 동일 이미지 Job, controller-manager 안정화 |

두 번째 유형은 control-plane static Pod 재시작 직후 Job controller가 아직 안정화되지 않은
짧은 구간에서도 발생할 수 있다. 다음과 같이 같은 pause image가 실제로 완료되는지
검증한다.

```bash
sudo KUBECONFIG=/etc/kubernetes/admin.conf kubectl -n kube-system create job \
  pause-health-test --image=registry.k8s.io/pause:3.10 -- /pause -v
sudo KUBECONFIG=/etc/kubernetes/admin.conf kubectl -n kube-system get pod \
  -l job-name=pause-health-test -o wide
sudo KUBECONFIG=/etc/kubernetes/admin.conf kubectl -n kube-system get job pause-health-test
```

Pod가 `Completed`, Job이 `1/1`이면 image, container runtime, scheduler와 기본 Job 처리는
정상이다. 검증 후 임시 Job을 삭제한다.

```bash
sudo KUBECONFIG=/etc/kubernetes/admin.conf kubectl -n kube-system delete job pause-health-test
```

Kubespray 재실행 중 health-check를 관찰하려면 별도 terminal에서 복수형 resource를 하나의
인자로 전달한다.

```bash
sudo KUBECONFIG=/etc/kubernetes/admin.conf kubectl -n kube-system get pods,jobs -w
```

`kubectl get nodes`의 `VERSION=v1.32.8`은 kubelet 버전만 보여준다. `kubeadm upgrade apply`가
preflight에서 실패했다면 control-plane이 실제로 upgrade됐다는 증거가 아니다.

```bash
sudo KUBECONFIG=/etc/kubernetes/admin.conf kubectl version
sudo KUBECONFIG=/etc/kubernetes/admin.conf kubectl -n kube-system get pod \
  -l component=kube-apiserver \
  -o custom-columns=NAME:.metadata.name,IMAGE:.spec.containers[0].image
sudo /usr/local/bin/kubeadm upgrade plan v1.32.8
```

Kubespray는 `kubeadm`을 `/usr/local/bin`에 설치한다. 일반 사용자 PATH에서는 `kubeadm`이
보여도 `sudo`의 secure PATH에서는 찾지 못할 수 있으므로 절대 경로를 사용한다. `sudo`
없이 실행하면 `/etc/kubernetes/admin.conf` 읽기 권한 때문에 실패한다.

`upgrade plan`에서 cluster health check가 통과하고 다음처럼 control-plane은 구버전,
kubelet만 목표 버전으로 표시될 수 있다.

```text
Cluster version: 1.31.9
kubeadm version: v1.32.8
kube-apiserver k8s-master v1.31.9 -> v1.32.8
kubelet        k8s-master v1.32.8 -> v1.32.8
```

이는 첫 실행이 kubelet package를 먼저 갱신한 뒤 `kubeadm upgrade apply` preflight에서
중단된 부분 upgrade 상태다. `upgrade plan`과 pause test가 통과했다면 수동 apply보다 원래
workflow를 다시 실행해 control-plane, kube-proxy, worker와 cleanup을 함께 수렴시킨다.

```bash
cd /home/rocky/homelab/ansible
make kubernetes-upgrade
```

event에서 `node.kubernetes.io/unschedulable` 때문에 health-check Pod가 배치되지 않은 것이
확인된 경우에만 다음 순서로 복구한다.

1. 실패한 Kubespray 프로세스가 종료됐는지 확인한다.
2. control-plane의 API, etcd, system Pod가 정상인지 확인한다.
3. 운영 승인 후 `kubectl uncordon k8s-master`를 수행한다.
4. `kubeadm upgrade plan v1.32.8`로 health check가 통과하는지 확인한다.
5. single-control-plane drain 순서 때문에 동일 오류가 재현된다면, schedulable 상태에서
   Kubespray가 생성한 `/etc/kubernetes/kubeadm-config.yaml`을 사용해 `kubeadm upgrade
   apply`를 완료한다.
6. control-plane/API 상태를 다시 확인한 뒤 원래 Kubespray workflow를 재실행하여 나머지
   role과 worker upgrade를 수렴시킨다.

```bash
sudo KUBECONFIG=/etc/kubernetes/admin.conf kubectl uncordon k8s-master
sudo /usr/local/bin/kubeadm upgrade plan v1.32.8
sudo /usr/local/bin/kubeadm upgrade apply -y v1.32.8 \
  --config=/etc/kubernetes/kubeadm-config.yaml \
  --skip-phases=addon/coredns
```

수동 `kubeadm upgrade apply`는 event로 unschedulable 원인이 확인되고 Kubespray 재시도가
동일하게 실패하는 single-control-plane 복구에만 사용한다. 성공 후 `make
kubernetes-upgrade`를 다시 실행하지 않고 끝내면 worker와 후속 role이 구버전에 남는다.

### Kubespray 실행 후 ArgoCD Pod가 `1/2 CrashLoopBackOff`가 되는 경우

대표 증상은 Helm으로 ArgoCD v3을 배포한 Pod에 Kubespray의 v2 컨테이너가 함께 존재하고,
v3 컨테이너가 동일 포트를 열지 못해 종료되는 것이다.

```text
argocd-server  quay.io/argoproj/argocd:v2.14.5
server         quay.io/argoproj/argocd:v3.0.0

level=fatal msg="listen tcp 0.0.0.0:8080: bind: address already in use"
```

원인은 nested Kubespray 호출의 `-e argocd_enabled=false`가 boolean이 아니라 `"false"`
문자열로 전달되고, Kubespray의 bare `when: argocd_enabled` 조건이 이를 truthy로 평가한
것이다. Kubespray의 client-side apply가 Helm chart 8 리소스를 대체하지 않고 서로 다른
이름의 v2 컨테이너를 Pod template에 병합한다.

다음 세 증거를 함께 확인한다.

```bash
helm -n argocd history argocd

helm -n argocd get manifest argocd |
  grep -nE 'name: (argocd-server|server|argocd-repo-server|repo-server)$|image:.*argocd'

kubectl -n argocd get deploy,statefulset -o json |
  jq -r '
    .items[]
    | select(.spec.template.spec.containers | length > 1)
    | .kind as $kind
    | .metadata.name as $name
    | .spec.template.spec.containers[]
    | [$kind, $name, .name, .image] | @tsv
  '
```

Helm manifest에는 v3 컨테이너만 있지만 live workload에 v2/v3 컨테이너가 함께 있으면
ownership이 섞인 것이다. managedFields와 last-applied annotation으로 적용 주체와 시간을
확인한다.

```bash
kubectl -n argocd get deployment argocd-server -o yaml --show-managed-fields |
  grep -nE 'manager:|operation:|time:|v2.14.5'

kubectl -n argocd get deployment argocd-server \
  -o jsonpath='{.metadata.annotations.kubectl\.kubernetes\.io/last-applied-configuration}' |
  jq -r '.spec.template.spec.containers[] | [.name, .image] | @tsv'
```

실제 사고에서는 Helm manager 적용 뒤 `kubectl-client-side-apply`가 v2.14.5 manifest를
적용한 것이 확인됐다. 이 상태는 Helm release 자체의 실패가 아니므로 먼저 rollback하지
않는다. Kubespray addon 재실행을 막는 코드 경계를 수정한 뒤, live template에서
Kubespray가 추가한 컨테이너만 제거한다.

```bash
kubectl -n argocd patch deployment argocd-server --type=strategic \
  -p '{"spec":{"template":{"spec":{"containers":[{"name":"argocd-server","$patch":"delete"}]}}}}'
kubectl -n argocd patch deployment argocd-repo-server --type=strategic \
  -p '{"spec":{"template":{"spec":{"containers":[{"name":"argocd-repo-server","$patch":"delete"}]}}}}'
kubectl -n argocd patch deployment argocd-applicationset-controller --type=strategic \
  -p '{"spec":{"template":{"spec":{"containers":[{"name":"argocd-applicationset-controller","$patch":"delete"}]}}}}'
kubectl -n argocd patch deployment argocd-notifications-controller --type=strategic \
  -p '{"spec":{"template":{"spec":{"containers":[{"name":"argocd-notifications-controller","$patch":"delete"}]}}}}'
kubectl -n argocd patch statefulset argocd-application-controller --type=strategic \
  -p '{"spec":{"template":{"spec":{"containers":[{"name":"argocd-application-controller","$patch":"delete"}]}}}}'
kubectl -n argocd patch deployment argocd-dex-server --type=strategic \
  -p '{"spec":{"template":{"spec":{"containers":[{"name":"dex","$patch":"delete"}]}}}}'
```

제거할 이름은 위의 live/Helm 비교로 먼저 확인한다. StatefulSet이 partitioned 또는
`OnDelete` 방식이면 template patch만으로 기존 Pod가 교체되지 않는다. template에 v3
컨테이너 하나만 남은 것을 확인한 뒤 기존 Pod를 재생성한다.

```bash
kubectl -n argocd get statefulset argocd-application-controller \
  -o jsonpath='{range .spec.template.spec.containers[*]}{.name}{"\t"}{.image}{"\n"}{end}'
kubectl -n argocd delete pod argocd-application-controller-0
kubectl -n argocd rollout status statefulset/argocd-application-controller --timeout=5m
```

복구 완료 기준은 모든 ArgoCD workload의 컨테이너가 Helm v3 기준 하나씩이고, Pod가 Ready,
Application이 정상적으로 reconcile되는 것이다.

```bash
kubectl -n argocd get pods
kubectl -n argocd get applications \
  -o custom-columns='NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status'
```

OpenBao는 node drain 뒤 sealed 상태로 다시 시작할 수 있으므로 ArgoCD 복구와 별도로 unseal
상태를 확인한다. 모든 workload 복구가 끝나면 전체 upgrade를 반복하지 말고 Phase 5의
postcheck만 실행한다.

### CNPG PDB가 drain을 차단하는 경우

```bash
ssh k8s-master 'sudo KUBECONFIG=/etc/kubernetes/admin.conf kubectl get cluster -A'
ssh k8s-master 'sudo KUBECONFIG=/etc/kubernetes/admin.conf kubectl get pdb -A'
ssh k8s-master 'sudo KUBECONFIG=/etc/kubernetes/admin.conf kubectl get pod -A -o wide | grep postgres'
```

PDB를 강제로 삭제하지 않는다. instance 수, primary/replica 위치, PVC node affinity를 확인해
drain 가능한 topology인지 판단한다.

### OpenBao가 `Running 0/1`인 경우

`Running 0/1`은 정상 상태가 아니다. upgrade나 node 재부팅 뒤 OpenBao는 sealed 상태로
기동될 수 있다.

```bash
ssh k8s-master 'sudo KUBECONFIG=/etc/kubernetes/admin.conf kubectl -n openbao get pods'
ssh k8s-master 'sudo KUBECONFIG=/etc/kubernetes/admin.conf kubectl -n openbao logs \
  statefulset/platform-openbao --tail=100'
```

초기 root token과 unseal key는 Git 또는 Kubernetes Secret에 저장하지 않는다. 운영자가
별도 보관한 키로 unseal한 뒤 Pod Ready와 ArgoCD Application health를 다시 확인한다.

## Phase 5. Kubernetes upgrade postcheck

```bash
make kubernetes-upgrade-postcheck
```

완료 기준:

- 모든 node의 kubelet version이 목표 버전이다.
- 모든 node가 `Ready`이고 schedulable 상태가 의도와 일치한다.
- API `/readyz`가 통과한다.
- system Pod와 일반 workload에 `0/N`, Pending, CrashLoopBackOff가 없다.
- CNPG, OpenBao 등 stateful workload가 Ready다.
- maintenance label/taint와 임시 상태가 정리되었다.

```bash
ssh k8s-master 'sudo KUBECONFIG=/etc/kubernetes/admin.conf kubectl get nodes -o wide'
ssh k8s-master 'sudo KUBECONFIG=/etc/kubernetes/admin.conf kubectl get --raw=/readyz?verbose'
ssh k8s-master 'sudo KUBECONFIG=/etc/kubernetes/admin.conf kubectl get pods -A'
```

postcheck가 실패하면 upgrade 성공으로 기록하지 않는다. 실패 workload를 복구한 뒤
postcheck만 다시 실행한다.

## Phase 6. Execution artifact 분석

```bash
operation=kubernetes-upgrade
run_id="$(ls -1t "runs/${operation}" | head -1)"
sed -n '1,220p' "runs/${operation}/${run_id}/summary.md"
sed -n '1,220p' "runs/${operation}/${run_id}/metadata.yml"
rg -n "FAILED|fatal:|undefined|has no attribute|unreachable" \
  "runs/${operation}/${run_id}/stdout.log"
```

확인 순서:

1. `summary.md`: PASS/FAIL/NOT VERIFIED와 주요 결과
2. `metadata.yml`: 실행 시각, commit, command, 종료 코드
3. `stdout.log`: Ansible task와 원인 메시지
4. `ansible.log`: 상세 callback 기록
5. `command.txt`: 실제 전달 인자

Secret이나 token이 발견되면 artifact를 공유하지 말고 credential 회전과 `no_log` 보완을
우선한다.

## 빠른 증상 색인

| 증상 | 먼저 확인할 phase | 핵심 조치 |
| --- | --- | --- |
| `pathspec '2.28.1'` | Phase 1 | `kubespray_version`을 실제 `v` tag와 일치 |
| `kube_version.startswith('v')` | Phase 2 | Kubernetes 버전의 선행 `v` 제거 |
| `helm_version.startswith('v')` | Phase 2 | 전역 변수 제거, `helm_cli_version` 사용 |
| `argocd_install_checksums...3.0.0` | Phase 2/3 | Kubespray addon 변수 경계 고정 |
| node별 버전 불일치 | Phase 4 | 변경 범위 확인 후 동일 workflow 재실행 |
| `upgrade-health-check` 15초 timeout | Phase 4 | event로 scheduler 원인 확인, single control-plane 복구 |
| ArgoCD `1/2`, `address already in use` | Phase 4 | Kubespray v2 중복 컨테이너 제거 후 addon boolean 경계 수정 |
| drain/PDB 차단 | Phase 2/4 | topology와 replica/PVC 확인, PDB 강제 삭제 금지 |
| OpenBao `Running 0/1` | Phase 4 | sealed 여부 확인 후 안전하게 unseal |
| worker `pool` label 없음 | Phase 2/5 | `make post-kubespray`로 label과 canonical taint 수렴 |
| postcheck workload 실패 | Phase 5 | workload 복구 후 postcheck 재실행 |
