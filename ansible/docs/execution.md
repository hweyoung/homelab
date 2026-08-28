# Ansible 실행과 Execution Artifact

## 공식 실행 경로

운영자는 `infra-bastion`의 `ansible/` 루트에서 Makefile을 사용한다.

```text
make <target>
  ↓
scripts/run-playbook.sh
  ↓
playbooks/site.yml 또는 playbooks/kubernetes/upgrade.yml
  ↓
playbooks/
  ↓
roles/
```

`playbooks/` 안으로 이동해 `ansible-playbook`을 직접 실행하지 않는다. 실행 기준 디렉터리,
`ansible.cfg`, Inventory, Role path와 artifact 생성 계약을 놓칠 수 있다.

## Controller 준비

```bash
./scripts/prepare-bastion.sh
```

이 스크립트는 controller Python 환경과 Kubespray checkout/runtime을 준비한다.

```text
.venv/               프로젝트 Ansible 환경
.kubespray-venv/     선택한 Kubespray release 전용 환경
kubespray/           pinned upstream checkout
```

두 virtualenv는 dependency pin 충돌을 피하기 위해 분리한다.

## 운영 target

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

전체 신규 bootstrap은 `make bootstrap`, 기존 cluster 업그레이드는 다음 target을 사용한다.

```bash
make kubernetes-upgrade-precheck
make kubernetes-upgrade
make kubernetes-upgrade-postcheck
```

## Artifact 구조

```text
runs/<operation>/<YYYYMMDD-HHMMSS>-<pid>/
├── metadata.yml      실행 환경, Git revision, 시작/종료와 결과
├── command.txt       민감 값이 가려진 호출 기록
├── ansible.log       Ansible logging output
├── stdout.log        터미널 stdout/stderr
└── summary.md        사람이 읽는 실행 요약과 recap
```

결과는 `success`, `failure`, `interrupted` 중 하나다. wrapper는 원래
`ansible-playbook` exit code를 반환한다.

## 보안 정책

- `umask 077`, Run Directory `0700`, 파일 `0600`
- `runs/` Git 제외
- 실제 Inventory 전체를 artifact에 저장하지 않음
- `-e @secrets.yml`은 참조만 기록
- 허용되지 않은 inline extra-var 값은 `REDACTED`
- password file, private key와 Vault ID source는 기록하지 않음
- ArgoCD 초기 admin password를 Playbook output에 표시하지 않음

허용된 비민감 제어 변수는 `kubernetes_upgrade_confirm`,
`kubernetes_upgrade_postcheck_only`, `kubespray_force`, `argocd_force`다. Secret은 CLI
inline 값이 아니라 Vault 파일로 전달한다.

## 읽기 전용 도구

```bash
make inventory
make syntax
make vault
```

이 target은 execution artifact를 만들지 않는다. `make ssh-check`는 대상 host에 Ansible
ping을 수행하므로 완전한 local-only 검사는 아니다.

## 실패 분석

```bash
ls -1t runs/<operation>/ | head
```

1. `summary.md`의 결과와 exit code
2. `metadata.yml`의 Git commit과 dirty 여부
3. `stdout.log`의 마지막 실패 task
4. 필요한 경우 `ansible.log`
5. `command.txt`의 Playbook, tag와 비민감 제어 변수

민감정보가 발견되면 artifact를 공유하지 말고 접근을 제한한 뒤 credential을 회전하고
`no_log` 누락을 수정한다.
