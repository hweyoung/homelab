# Helm CLI Upgrade Runbook

`infra-bastion`에서 control-plane의 기존 Helm CLI 바이너리를 안전하게 교체하는 절차다.
신규 설치는 `make helm`, 기존 바이너리의 version 변경은 이 workflow만 사용한다.

```text
playbooks/upgrade.yml --tags helm_upgrade_*
  → validate → precheck → approved upgrade → postcheck
```

## Version 선택

`inventories/homelab/group_vars/all.yml`의 `helm_cli_version`을 목표 version으로 설정한다.
Helm이 빌드된 Kubernetes client minor와 cluster version의 공식 `n-3` 호환 범위를 먼저
확인한다. 현재 Kubernetes 1.31에는 Helm 3.19.x 또는 Helm 4.0.x가 공식 범위에 포함된다.

일반 patch/minor upgrade는 동일 major 안에서 더 높은 version만 허용한다. Helm 2는 release
storage migration이 필요하므로 자동화 대상에서 제외한다. Helm 3에서 4로의 전환은 기존
release migration 없이 가능하지만 plugin, 변경된 CLI flag, CI/CD와 chart workflow 검증이
필요하므로 별도 major 승인 target을 사용한다. ArgoCD deploy Role은 설치된 Helm major에 따라
Helm 3의 `--atomic`과 Helm 4의 `--rollback-on-failure`를 선택한다.

## 실행

```bash
make helm-upgrade-precheck
```

precheck는 다음을 수행하며 설치된 바이너리는 변경하지 않는다.

- 공식 archive와 `sha256sum` 다운로드 및 검증
- staging 바이너리의 목표 version 확인
- 기존 바이너리와 staging 바이너리가 같은 release 목록을 인식하는지 확인
- major upgrade 시 설치된 plugin 목록 출력

검토 후 동일 major upgrade를 실행한다.

```bash
make helm-upgrade
```

Helm 3→4처럼 major가 바뀌는 경우에만 다음 target을 사용한다.

```bash
make helm-upgrade-major
```

기존 바이너리는 `/usr/local/bin/helm.backup-<current-version>`에 보존한다. 교체 직후 version
또는 cluster release 조회가 실패하면 Role이 기존 바이너리를 즉시 복원한다.

독립 사후 점검은 다음과 같다.

```bash
make helm-upgrade-postcheck
```

## 운영 원칙

- Kubernetes upgrade와 Helm major upgrade를 같은 maintenance에서 수행하지 않는다.
- Helm CLI binary 교체는 release revision이나 Kubernetes resource를 변경하지 않는다.
- Helm 4 전환 전 기존 chart와 자동화에서 변경된 flag를 확인한다.
- backup 바이너리는 새 version 검증 후 운영자가 별도로 정리한다.
