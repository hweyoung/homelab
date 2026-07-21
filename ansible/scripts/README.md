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
- Kubespray 의 Python 의존성 설치
- 인벤토리 점검

Ansible 이 돌 머신 자체를 준비하는 단계라 shell 로 유지합니다.

### `sync-kubespray.sh`

로컬 `kubespray/` 체크아웃을 `inventories/homelab/group_vars/all.yml` 의
`kubespray_version` 에 고정시킵니다.

## Ansible 진입 래퍼

`run-ansible.sh`, `run-inventory.sh`, `run-adhoc.sh` 는 `ansible-env.sh` 의 공통 환경을
로드한 뒤 각각 `ansible-playbook`, `ansible-inventory`, `ansible` 에 인자를 그대로
넘기는 얇은 래퍼입니다. 소유권 경계가 아니라 편의용입니다.

`run-vault.sh` 는 같은 환경을 로드한 뒤 `ansible-vault` 를 감쌉니다. 이 저장소에서 vault
로 다루는 파일은 `secrets.yml` 뿐이라, 대상 파일을 생략하면 자동으로 `secrets.yml` 을
붙입니다.

```bash
./scripts/run-vault.sh              # = ansible-vault edit secrets.yml
./scripts/run-vault.sh view         # = ansible-vault view secrets.yml
./scripts/run-vault.sh encrypt      # = ansible-vault encrypt secrets.yml
./scripts/run-vault.sh view path/to/other.yml   # 파일을 명시하면 그대로 전달
```

`secrets.yml` 에 `sops_age_private_key`(age private key) 를 채우는 것도 이 래퍼로 합니다.
자세한 내용은 루트 `../README.md` §4 참고.

## 직접 호출 금지

`playbooks/` 안에서 `ansible-playbook` 을 직접 호출하면 `ansible.cfg`, 인벤토리, 로컬
role 을 모두 놓칩니다. 반드시 저장소 루트에서 `make` 혹은 `scripts/run-*.sh` 를 통해
실행하세요.
