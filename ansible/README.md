# ansible — 홈랩 부트스트랩 자동화

홈랩 저장소의 **부트스트랩 단계**를 담당하는 Ansible 코드. Terraform 으로 VM 이 만들어진
직후 시작되고, ArgoCD root Application 이 떨어지는 순간 임무가 끝납니다. 그 이후의 모든
플랫폼·앱 리소스는 `gitops/` 가 ArgoCD 를 통해 가져갑니다.

```text
terraform/  →  ansible/  →  gitops/ (ArgoCD)
   VM        부트스트랩       클러스터 상태
```

---

## 1. 목적 (Purpose)

이 폴더가 **소유**하는 범위:

- Bastion(`infra-bastion`) SSH 포트 / SELinux / firewalld 구성
- Bastion `/etc/hosts` 인벤토리 매핑
- Tailscale 설치 및 Tailnet 조인 (관리 평면)
- Kubespray 실행 래퍼 (Kubernetes 클러스터 자체 부트스트랩)
- Post-Kubespray 노드 라벨링 / prod taint / SSH 사용자 kubeconfig 설치
- Helm CLI 바이너리 설치 (ArgoCD 설치용)
- SOPS age key 를 argocd ns 에 Secret 으로 주입 (ksops 복호화용)
- ArgoCD Helm chart 설치 (Ingress + ksops repo-server 통합)
- `gitops/bootstrap/root.yaml` 적용 — App-of-Apps 발화점

이 폴더가 **위임**하는 범위 — Ansible 이 손대지 않고 GitOps(ArgoCD)에 넘기는 것들:

- Traefik Gateway / cert-manager / cloudflared / Dex / ArgoCD Image Updater
- MinIO / CloudNativePG / observability stack (Prometheus, Grafana, Loki, Alloy)
- 네임스페이스 / RBAC / NetworkPolicy / ResourceQuota / LimitRange / PSA
- prod·dev 앱 자체

경계가 모호해지면 운영이 흔들리므로, 새 작업이 들어왔을 때 "Ansible 이 한 번만 만들고
끝나는 것인가, 지속적으로 reconcile 되어야 하는가" 를 먼저 묻고 후자라면 `gitops/` 로
보냅니다.

---

## 2. 노드 레이아웃

| Host              | 역할                                            |
| ----------------- | ----------------------------------------------- |
| `infra-bastion`   | Ansible 컨트롤러, Kubespray, Tailscale subnet router |
| `k8s-master`      | control plane, etcd                             |
| `k8s-worker-prod` | prod apps, stable platform, MinIO               |
| `k8s-worker-dev`  | dev apps, mutable platform, ArgoCD, Grafana     |

실제 IP · 사용자 · LAN CIDR 은 저장소에 커밋하지 않습니다. `inventories/homelab/hosts.yml`
(gitignore) 에만 두며, 형식은 `hosts.yml.example` 을 참고하세요.

`infra-bastion` 은 **Ansible 컨트롤러 그 자체**이므로 인벤토리에 `ansible_connection: local`
로 등록되어 있습니다. 즉 노트북에서 Ansible 을 돌리는 게 아니라, infra-bastion 에 SSH 로
들어가서 거기서 `make` 를 호출하는 흐름입니다.

---

## 3. 디렉토리 구조

```text
ansible/
├── ansible.cfg
├── Makefile                          # 단계별 진입점
├── README.md
├── site.yml                          # 전체 진입점 (모든 play 를 태그별로 포함)
├── requirements-controller.txt       # 컨트롤러 Python 의존성
├── secrets.example.yml               # Vault 시크릿 템플릿
├── inventories/
│   └── homelab/
│       ├── hosts.yml                  # 실제 IP/사용자 (gitignore)
│       ├── hosts.yml.example          # 인벤토리 템플릿 (커밋됨)
│       └── group_vars/
│           ├── all.yml               # 프로젝트 전역 변수 (helm/argocd/kubespray 버전)
│           ├── k8s_cluster.yml       # Kubespray 클러스터 설정 (network_plugin 등)
│           ├── tailscale_nodes.yml
│           └── bastion.yml
├── roles/
│   ├── bastion_ssh/                  # tasks: configure / selinux / firewall
│   ├── bastion_hosts/                # tasks: main
│   ├── tailscale/                    # tasks: install / configure / join
│   ├── kubespray_runner/             # Kubespray 사전검증 + 실행 (localhost play)
│   ├── k8s_node_config/              # tasks: kubeconfig / labels / taints
│   ├── helm/                         # tasks: install
│   └── argocd/                       # tasks: prereq / deploy / verify
│       └── templates/argocd-values.yaml.j2
└── scripts/
    ├── README.md                     # shell 과 ansible 의 분담 정리
    ├── ansible-env.sh                # 공통 환경변수 + .venv 활성화
    ├── prepare-bastion.sh            # 컨트롤러(infra-bastion) 1회 부트스트랩
    ├── sync-kubespray.sh             # ./kubespray 를 pinned tag 로 체크아웃
    ├── run-ansible.sh                # ansible-playbook 래퍼
    ├── run-inventory.sh              # ansible-inventory 래퍼
    └── run-adhoc.sh                  # ansible (ad-hoc) 래퍼
```

**커밋하지 않는 런타임/로컬 상태** (`.gitignore` 처리됨):

- `kubespray/` — `sync-kubespray.sh` 가 만드는 외부 체크아웃
- `.venv/` — `prepare-bastion.sh` 가 만드는 Python 가상환경
- `secrets.yml` — Ansible Vault 로 암호화된 로컬 시크릿 (예시: `secrets.example.yml`)
- `inventories/homelab/hosts.yml` — 실제 노드 IP·사용자 (예시: `hosts.yml.example`)
- `.ansible/` — Ansible 임시 파일

### 설계 원칙

1. **단일 진입점 + 태그**: `site.yml` 하나가 모든 play 를 포함하고, 각 play 가 단일 role
   하나만 호출합니다. 부분 실행은 `--tags <stage>` 로 제어합니다. `make` 타깃도 동일한
   태그를 감싸는 얇은 래퍼입니다.
2. **per-role 책임 분리**: 각 role 의 `tasks/main.yml` 은 import 만 합니다. 실제 로직은
   `install.yml`, `configure.yml`, `service.yml` 처럼 책임별로 쪼개져 있어, 한 파일을
   열었을 때 무엇을 하는 단계인지 명확합니다.
3. **shell 과 Ansible 분담**: 컨트롤러 자체를 만드는 단계(Python venv, Kubespray clone)
   는 shell, 호스트 구성과 클러스터 부트스트랩은 전부 Ansible 입니다. 자세한 경계는
   `scripts/README.md` 참고.
4. **재실행 안전성 (멱등성)**: 비싼 단계 — `kubespray` (cluster.yml 30–45분), `tailscale`
   (auth-key API 호출), `argocd` (helm upgrade --wait) — 는 실행 직전에 현재 상태를
   먼저 확인하고, 이미 원하는 상태면 핵심 명령 자체를 스킵합니다. 그 외 단계는 Ansible
   모듈이 가지는 본래의 idempotency 에 의존합니다. 강제 재적용이 필요할 땐 §5.4 의 escape
   hatch 를 사용합니다.

---

## 4. 준비 (한 번만)

`infra-bastion` 으로 SSH 접속한 뒤 컨트롤러 런타임을 만듭니다.

```bash
ssh <user>@<bastion-ip>          # hosts.yml 의 infra-bastion 값
cd /path/to/homelab/ansible
./scripts/prepare-bastion.sh
```

`prepare-bastion.sh` 가 자동으로 처리하는 것:

- Rocky/RHEL dnf 패키지 설치 (`gcc`, `git`, `python3.11+`, `python3-libselinux` 등)
- `.venv` 생성 + `requirements-controller.txt` 설치
- `./scripts/sync-kubespray.sh` 호출 → `inventories/homelab/group_vars/all.yml`
  의 `kubespray_version` 으로 `./kubespray` 체크아웃
- `kubespray/requirements.txt` 설치
- 인벤토리 그래프 출력으로 sanity check

시크릿 파일은 처음 한 번만 만들어 두면 됩니다. `secrets.yml` 은 최소 두 개의 키를
채워야 합니다.

```bash
cp secrets.example.yml secrets.yml
# 평문 상태에서 값 두 개를 채운다:
#   tailscale_auth_key   : Tailscale 재사용 auth key (tskey-auth-...)
#   sops_age_private_key : age private key (AGE-SECRET-KEY-...)  ← 아래 주의 참고
ansible-vault encrypt secrets.yml
# 나중에 값을 고칠 때는:  ansible-vault edit secrets.yml
```

> **`sops_age_private_key` 는 아무 키나 새로 만들면 안 됩니다.** 반드시 리포 루트
> `.sops.yaml` 의 `age:` 공개키와 **짝이 맞는** private key 여야 합니다. 그래야 클러스터에
> 주입된 `sops-age` Secret 으로 기존 `*.sops.yaml` 이 복호화됩니다. 새 키로 덮으면
> 공개키가 달라져 **기존 암호문을 하나도 못 풉니다.**
>
> 이 값이 비어 있거나(`CHANGE_ME`) `-e @secrets.yml` 없이 실행하면 `make sops`
> (site.yml step 7)의 `sops_age_private_key 검증` task 가 아래처럼 **fail-fast** 로 멈춥니다 —
> 버그가 아니라 "키를 아직 안 넣었다" 는 신호입니다.
>
> ```text
> sops_age_private_key 가 secrets.yml 에 설정되지 않았습니다.
> AGE-SECRET-KEY-... 로 시작하는 키를 입력한 뒤 `-e @secrets.yml` 로 다시 실행하세요.
> ```
>
> **짝 검증** — 키를 만든 곳(예: 로컬 맥북)에서 `age-keygen -y <keys.txt>` 결과가
> `.sops.yaml` 의 `age:` 값과 같아야 한다. 값을 넣은 뒤 `make sops` 로 주입한다.
> 키가 이미 만들어져 있으니 **k8s-master 등 노드에서 `age-keygen` 을 새로 돌리지 않는다.**
> (키를 분실해 회전이 필요한 경우의 절차는 `../gitops/SECRETS.md` 참고.)

GitOps 저장소(repo URL/revision)는 `gitops/bootstrap/root.yaml` 안에서 관리합니다.
Ansible 은 이 파일을 그대로 클러스터에 적용하기만 하므로 인벤토리에는 경로
(`gitops_root_app_path`) 만 둡니다.

### 로컬 sops 편집 준비 (선택 — `*.sops.yaml` 을 직접 만들/편집할 때만)

`gitops/` 의 `*.sops.yaml` 을 **이 컨트롤러에서 `sops` CLI 로 만들거나 편집**하려면
age **private key** 가 로컬 파일로 있어야 합니다. 반면 **런타임 복호화(ArgoCD/KSOPS)**
는 `argocd` role(`tasks/sops_age.yml`)이 클러스터 `sops-age` Secret 으로 이미 처리하므로 —
**k8s-master 를 포함한 어떤 노드에도 이 키 파일은 필요하지 않습니다.** 오직 사람이
`sops` 를 실행하는 머신(여기서는 컨트롤러 `infra-bastion`) 에만 둡니다.

age private key 의 유일한 출처는 Vault 로 암호화된 `secrets.yml` 이므로 거기서 꺼내 씁니다.

```bash
mkdir -p ~/.config/sops/age && chmod 700 ~/.config/sops/age

# secrets.yml 에서 sops_age_private_key 값만 추출해 keys.txt 로 저장
ansible-vault view secrets.yml \
  | awk -F'"' '/^sops_age_private_key:/ {print $2}' \
  > ~/.config/sops/age/keys.txt
chmod 600 ~/.config/sops/age/keys.txt

# 검증 — 여기서 나오는 공개키가 gitops/.sops.yaml 의 age: 값과 같아야 함
age-keygen -y ~/.config/sops/age/keys.txt
```

`sops` 는 기본적으로 `~/.config/sops/age/keys.txt` 를 찾습니다. 다른 경로에 두려면
`SOPS_AGE_KEY_FILE` 로 지정하세요. 실제 암호화/편집 절차는 `../gitops/SECRETS.md` 를
참고합니다.

---

## 5. 사용방법

모든 명령은 `ansible/` 루트에서 실행합니다. `playbooks/` 안에서 `ansible-playbook` 을
직접 호출하면 `ansible.cfg`, 인벤토리, 로컬 role 을 모두 놓칩니다.

### 전체 부트스트랩

```bash
make all
```

내부적으로 `prepare → inventory → syntax → tailscale → bootstrap` 순서로 실행됩니다.
`bootstrap` 타깃은 `site.yml -e @secrets.yml --ask-vault-pass` 와 동치.

다시 실행해도 안전합니다 — 이미 끝난 단계는 사전 체크로 스킵됩니다 (자세한 동작은 아래
표의 *재실행 시 동작* 컬럼과 §5.4 참고).

### 단계별 실행 (tag 기반)

| Make 타깃             | 대응 태그         | 무엇을 하는가                                          | 재실행 시 동작                                |
| --------------------- | ----------------- | ------------------------------------------------------ | --------------------------------------------- |
| `make bastion-ssh`    | `bastion_ssh`     | bastion sshd 포트 / SELinux / firewalld                | Ansible 모듈 기반 idempotent                  |
| `make bastion-hosts`  | `bastion_hosts`   | bastion `/etc/hosts` 인벤토리 매핑                      | `blockinfile` marker 로 idempotent            |
| `make tailscale`      | `tailscale`       | Tailscale 설치 + Tailnet 조인 (vault 필요)             | 로그인된 노드는 `tailscale up` 자체를 스킵    |
| `make kubespray`      | `kubespray`       | `./kubespray/cluster.yml` 실행                          | k8s-master 에 `admin.conf` 있으면 스킵        |
| `make post-kubespray` | `post_kubespray`  | kubeconfig 배포, 노드 라벨, prod taint                 | `kubectl … --overwrite` 로 상태 단언          |
| `make helm`           | `helm`            | k8s-master 에 Helm CLI 설치                             | `helm version` 으로 사전 검사                  |
| `make sops`           | `sops`            | age 비공개키를 argocd ns `sops-age` Secret 으로 주입 (vault 필요) | 입력 키와 동일 내용이면 Secret 변경 안 함     |
| `make argocd`         | `argocd`          | ArgoCD Helm chart 설치 + ksops 통합 + root.yaml 적용   | 동일 차트 버전이 deployed 면 helm upgrade 스킵 |

> `make sops` 는 `secrets.yml` 의 `sops_age_private_key` 를 요구합니다. 값이 비어 있거나
> `-e @secrets.yml` 없이 돌리면 `sops_age_private_key 검증` task 가 fail-fast 로 멈춥니다.
> 넣을 키/짝 검증 방법은 §4 를 참고하세요. (`make sops` 타깃은 `-e @secrets.yml
> --ask-vault-pass` 를 이미 포함합니다.)

`make` 를 쓰지 않고 직접 호출해도 동일합니다.

```bash
ansible-playbook site.yml --tags kubespray
ansible-playbook site.yml --tags argocd
```

### 점검

```bash
make inventory     # ansible-inventory --graph 로 인벤토리 트리 확인
make syntax        # site.yml 문법 검사
make ssh-check     # k8s_cluster 그룹 전체에 ad-hoc ping
ssh <user>@<k8s-master-ip> kubectl get nodes -o wide --show-labels
ssh <user>@<k8s-master-ip> kubectl get pods -n argocd
```

### 강제 재실행 / drift 보정

위 표대로 재실행은 기본적으로 안전합니다. 다만 "이미 설치됨" 분기는 **차트 버전이나
auth 상태처럼 식별이 쉬운 신호**만 봅니다. values 파일을 수정했는데 차트 버전은 그대로
이거나, Tailscale advertise-routes 만 바꾼 경우엔 자동 감지가 안 됩니다. 그럴 땐:

| 상황 | 방법 |
| --- | --- |
| Kubespray 를 강제로 다시 돌리고 싶다 | `ansible-playbook site.yml --tags kubespray -e kubespray_force=true` |
| ArgoCD values 만 바꿔서 반영하고 싶다 | `ansible-playbook site.yml --tags argocd -e argocd_force=true` |
| ArgoCD 차트 버전 올림 | `argocd_chart_version` 만 수정 → `make argocd` (자동 감지) |
| Tailscale hostname/route 변경 | 해당 노드에서 `tailscale logout` 후 `make tailscale`, 또는 `tailscale set ...` |
| Helm 버전 올림 | `/usr/local/bin/helm` 삭제 후 `make helm`, 또는 `helm_version` 변경 |

`kubespray_force` 와 `argocd_force` 는 어디에도 default 가 정의되어 있지 않습니다. CLI
로 전달할 때만 활성화되므로, 평상시 `make all` 을 다시 돌려도 의도치 않게 helm upgrade
나 cluster.yml 이 재실행될 일은 없습니다.

---

## 6. 부트스트랩 이후 ArgoCD 접속

`make argocd` 실행 끝에 `verify.yml` 이 admin 초기 비밀번호를 출력합니다. 나중에 다시
볼 때:

```bash
ssh <user>@<k8s-master-ip> \
  'kubectl -n argocd get secret argocd-initial-admin-secret \
     -o jsonpath="{.data.password}" | base64 -d' ; echo
```

**Traefik 이 아직 배포되지 않은 시점** (Ansible 부트스트랩 직후) 에는 Ingress 가 paper
리소스이므로 port-forward + SSH 터널로 접속합니다.

```bash
ssh -L 8080:localhost:8080 <user>@<k8s-master-ip> \
  'kubectl -n argocd port-forward svc/argocd-server 8080:80'
# 브라우저: http://localhost:8080  (admin / 위 비밀번호)
```

**Traefik 이 GitOps 로 배포된 이후** 에는 `argocd.homelab.local` 도메인이 살아납니다.
노트북의 `/etc/hosts` 에 매핑하거나 Tailscale MagicDNS / split DNS 로 해석하게 만든 뒤
브라우저로 직접 접속하면 됩니다.

`server.insecure: "true"` 설정이라 ArgoCD 자체는 HTTP 로 서비스합니다. TLS 는 Traefik
쪽에서 처리합니다.

---

## 7. 참고

- `scripts/README.md` — shell 헬퍼 vs Ansible role 의 책임 경계
- `secrets.example.yml` — Vault 가 요구하는 키 목록
- 루트 `../README.md` — homelab 저장소 전체 구조와 GitOps 영역
