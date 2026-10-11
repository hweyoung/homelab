# Script Roles

`scripts/` 안에는 컨트롤러(Ansible 가 실행되는 머신, 즉 infra-bastion) 부트스트랩과
ansible 진입 래퍼만 둡니다. 호스트/클러스터 구성 그 자체는 Ansible role 이 담당합니다.

## 컨트롤러 부트스트랩

### `prepare-bastion.sh`

`infra-bastion` 컨트롤러 런타임을 처음부터 끝까지 준비합니다.

- Rocky/RHEL 시스템 패키지 설치
- `.venv` 생성 (Python 3.11+)
- 컨트롤러 측 Python 의존성 설치 (`requirements-controller.txt`)
- pinned Kubespray release 체크아웃 (`sync-kubespray.sh` 호출)
- Kubespray 전용 `.kubespray-venv` 생성과 release별 Python 의존성 설치
- 인벤토리 점검

Ansible 이 돌 머신 자체를 준비하는 단계라 shell 로 유지합니다.

### `sync-kubespray.sh`

로컬 `kubespray/` 체크아웃을 `inventories/homelab/group_vars/all.yml` 의
`kubespray_version` 에 고정시킵니다. `.venv`가 준비되어 있으면 checkout 직후 별도
`.kubespray-venv`를 만들고 해당 release의 `kubespray/requirements.txt`를 설치합니다.
프로젝트 controller의 Ansible pin과 Kubespray release의 Ansible pin은 서로 덮어쓰지 않는다.

## 운영 Playbook 래퍼

### `run-playbook.sh`

Makefile의 운영 Playbook target이 사용하는 공식 실행 wrapper다.

```bash
./scripts/run-playbook.sh <operation> <playbook> [ansible arguments...]
```

실행마다 다음 artifact를 생성하고 원래 `ansible-playbook` exit code를 반환한다.

```text
runs/<operation>/<run-id>/
├── metadata.yml
├── command.txt
├── ansible.log
├── stdout.log
└── summary.md
```

Run Directory는 `0700`, 파일은 `0600`으로 생성된다. Vault 파일은 경로만 기록하고,
허용되지 않은 inline extra-var와 password/private-key 관련 옵션 값은 command history에서
가린다. Secret은 `-e key=value`가 아니라 Vault 파일로 전달한다.

일반 운영자는 이 스크립트를 직접 조합하기보다 Make target을 사용한다.

## 호환 및 Utility 래퍼

`run-ansible.sh`, `run-inventory.sh`, `run-adhoc.sh` 는 `ansible-env.sh` 의 공통 환경을
로드한 뒤 각각 `ansible-playbook`, `ansible-inventory`, `ansible` 에 인자를 그대로
넘기는 얇은 래퍼다. `run-ansible.sh`는 syntax-check와 읽기 전용 Playbook 검사에 사용하며
운영 Playbook 실행 이력을 만들지 않는다.

`run-vault.sh` 는 같은 환경을 로드한 뒤 `ansible-vault` 를 감쌉니다. 이 저장소에서 vault
로 다루는 파일은 `secrets.yml` 뿐이라, 대상 파일을 생략하면 자동으로 `secrets.yml` 을
붙인다.

```bash
./scripts/run-vault.sh              # = ansible-vault edit secrets.yml
./scripts/run-vault.sh view         # = ansible-vault view secrets.yml
./scripts/run-vault.sh encrypt      # = ansible-vault encrypt secrets.yml
./scripts/run-vault.sh view path/to/other.yml   # 파일을 명시하면 그대로 전달
```

`secrets.yml`에 `sops_age_private_key`를 설정할 때도 이 래퍼를 사용한다. 실제 값을 터미널
로그나 execution artifact에 복사하지 않는다.

## 직접 호출 금지

`playbooks/` 안에서 `ansible-playbook`을 직접 호출하면 실행 기준 디렉터리, `ansible.cfg`,
Inventory, Role path와 execution artifact 계약을 놓칠 수 있다. 반드시 `ansible/` 루트에서
Makefile을 사용한다.

상세 실행 및 보안 정책은 [execution.md](../docs/execution.md)를 참고한다.
