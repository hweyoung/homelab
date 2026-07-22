# Secret 관리 (SOPS + age)

GitOps 리포에는 **평문 Secret 을 커밋하지 않는다.** 모든 민감정보는 SOPS 로 암호화한
`*.sops.yaml` 파일로만 저장하고, ArgoCD(KSOPS)가 sync 시점에 복호화한다.

```text
개발자 ──sops -e──▶ *.sops.yaml (암호문) ──git push──▶ repo
                                                        │
argocd-repo-server (KSOPS + age key) ──복호화──▶ 클러스터 Secret
```

---

## 키 모델

| 항목 | 위치 | 비고 |
| --- | --- | --- |
| age **private key** | ansible `secrets.yml` (Ansible Vault) | 리포에 평문으로 두지 않음 |
| age private key (런타임) | argocd ns `sops-age` Secret | `argocd` role(`tasks/sops_age.yml`)이 주입 |
| age **public key** (recipient) | 리포 루트 `.sops.yaml` | 암호화 대상. `age-keygen -y keys.txt` 로 추출 |

- 복호화 인프라는 **ansible 이 이미 구성**한다:
  - `ansible/roles/argocd/tasks/sops_age.yml` → `sops-age` Secret 생성/회전
  - `ansible/roles/argocd/templates/argocd-values.yaml.j2` → repo-server 에 KSOPS
    initContainer + age 키 마운트(`SOPS_AGE_KEY_FILE=/home/argocd/.config/sops/age/keys.txt`)
- `.sops.yaml` 규칙: 파일명이 `*.sops.yaml` 인 것만 암호화하며, Secret 의
  `data`/`stringData` 값만 암호화하고 키/메타데이터는 평문으로 남긴다(`encrypted_regex`).

> `.sops.yaml` 의 `age:` 에는 이 리포의 age 공개키(`age1...`)가 설정되어 있어 `sops -e` 가
> 바로 동작한다. 키를 회전하면 공개키(`age-keygen -y keys.txt` 로 추출)를 여기서 교체하고,
> private key 는 ansible `secrets.yml` → `sops-age` Secret 을 함께 갱신한다.

---

## 암호화 대상 Secret 목록

| Secret | 용도 | 소유 namespace | 배치 위치(예) |
| --- | --- | --- | --- |
| ArgoCD repo credentials (부가) | 추가 private repo / helm registry 접근 | `argocd` | `clusters/homelab/argocd-config/` |
| Cloudflare API token | cert-manager DNS-01 challenge | `cert-manager` | `<cert-manager 워크로드>/` |
| Dex client secret | OIDC client 인증 | `dex` | `<dex 워크로드>/` |
| MinIO credentials | 오브젝트 스토리지 root 자격증명 | `minio` | `<minio 워크로드>/` |
| PostgreSQL dev credentials | dev DB superuser/app 자격증명 | `postgresql-dev` | `<postgresql dev 워크로드>/` |
| PostgreSQL prod credentials | prod DB superuser/app 자격증명 | `postgresql-prod` | `<postgresql prod 워크로드>/` |
| GHCR credentials | 컨테이너 이미지 pull(imagePullSecret) | 각 앱 ns | `<앱 워크로드>/` |

각 Secret 은 자신을 사용하는 워크로드 디렉토리에 `<이름>.sops.yaml` 로 둔다.

> **예외 — root repo credential 은 SOPS 로 관리하지 않는다.** App-of-Apps 의
> `root.yaml` 이 가리키는 repo 가 private 이면, ArgoCD 는 그 repo 를 pull 해야
> `*.sops.yaml` 을 복호화할 수 있는데 credential 자체가 그 repo 안에 있으면
> 닭-달걀이 된다. 따라서 이 credential 은 age 키와 같은 **부트스트랩 시크릿**으로
> 취급하여 ansible 이 out-of-band 로 주입한다:
> `ansible/roles/argocd/tasks/repo_credentials.yml` (PAT 는 Ansible Vault
> `secrets.yml` 의 `argocd_repo_pat`). 위 표의 "ArgoCD repo credentials (부가)" 는
> root repo 가 아닌 **추가** repo / helm registry 접근용에 한한다.

---

## 평문 금지 / placeholder 기준

- **평문 Secret 커밋 금지.** 실제 값이 들어간 Secret 은 반드시 `sops -e` 후 `*.sops.yaml` 로만 커밋한다.
- **예시/샘플**은 값에 placeholder(`REPLACE_ME`, `<...>`)를 쓰고 파일명을 `*.example.yaml` 로 둔다.
  (CI 의 평문 Secret/placeholder 검사에서 `*.example.yaml` 은 예외 처리된다.)
- `kubeconfig`, private key(`*.pem`, `id_rsa`), `.env` 등은 리포에 커밋하지 않는다(CI 가 차단).

---

## 새 Secret 추가 절차

```bash
# 1) 평문 Secret manifest 를 <이름>.sops.yaml 로 작성 (data/stringData 에 실제 값)
# 2) in-place 암호화 — .sops.yaml 규칙에 따라 age 로 암호화됨
sops -e -i path/to/<이름>.sops.yaml
# 3) 암호문 확인 후 커밋 (data/stringData 값이 ENC[...] 로 바뀌고 sops: 블록이 붙는다)
git add path/to/<이름>.sops.yaml
# 4) kustomize/Application 에서 이 파일을 참조
```

수정할 때는 `sops path/to/<이름>.sops.yaml` 로 에디터를 열어 편집하면 저장 시 재암호화된다.

---

## 부트스트랩 Secret 값 변경(회전) 절차

`*.sops.yaml` 로 관리하는 GitOps Secret 과 달리, **age 키**와 **ArgoCD root repo
credential(GitHub PAT)** 은 ansible 이 out-of-band 로 주입하는 부트스트랩 Secret 이다
(값의 출처는 Ansible Vault `secrets.yml`). 두 태스크 모두 멱등적이라 —
클러스터의 현재 Secret 값과 `secrets.yml` 값을 비교해 다를 때만 재적용한다 —
회전의 기본형은 **① `secrets.yml` 값 교체 → ② `--tags sops` 재실행** 이다.

```bash
# secrets.yml 이 vault 암호화돼 있으면 ansible-vault edit, 아니면 직접 편집
ansible-vault edit ansible/secrets.yml

# argocd ns 의 시크릿 주입 태스크만 재실행 (암호화돼 있으면 --ask-vault-pass 추가)
ansible-playbook ansible/site.yml -e @ansible/secrets.yml --tags sops
```

### GitHub PAT 회전 (간단)

1. GitHub 에서 새 PAT 발급 (대상 repo 의 Contents:read).
2. `secrets.yml` 의 `argocd_repo_pat` 를 새 값으로 교체.
3. `--tags sops` 재실행 → `argocd-repo-homelab` Secret 이 갱신된다.
4. GitHub 에서 **옛 PAT 를 revoke** 한다.

> repo credential 은 ArgoCD 가 라벨(`argocd.argoproj.io/secret-type: repository`) 붙은
> Secret 을 API 로 읽으므로 **repo-server 재시작이 필요 없다** — 다음 reconcile 에 반영된다.

### age 키 회전 (변경 시 주의 ⚠️)

age 키는 **키쌍**이라 private 키만 바꾸면 옛 public 키로 암호화해 둔 기존
`*.sops.yaml` 을 복호화할 수 없다. 반드시 아래 순서를 지킨다.

```bash
# 1) 새 키쌍 생성
age-keygen -o keys.txt
# 2) 리포 루트 .sops.yaml 의 age: recipient 를 새 public 키로 교체
age-keygen -y keys.txt          # age1... public 키 추출
# 3) 기존 *.sops.yaml 을 전부 새 키로 재암호화 (이 단계를 빼먹으면 회전 후 전부 복호화 실패)
find gitops -name '*.sops.yaml' -exec sops updatekeys -y {} \;
# 4) secrets.yml 의 sops_age_private_key 를 새 private 키로 교체 후 주입
ansible-playbook ansible/site.yml -e @ansible/secrets.yml --tags sops
# 5) 재암호화 결과 커밋
git add gitops .sops.yaml && git commit -m "chore: rotate age key"
```

> **함정 1 — 재암호화 필수**: 3번(`sops updatekeys`)을 빼먹으면 새 키로 기존 Secret 을
> 복호화하지 못해 모든 sync 가 실패한다.
> **함정 2 — repo-server 재시작 필요**: age 키는 `argocd-values.yaml.j2` 에서 `subPath`
> 마운트(`subPath: keys.txt`)라 Kubernetes 특성상 Secret 이 바뀌어도 마운트 파일이
> 자동 갱신되지 않는다. sops-age Secret 갱신 후 반드시 재시작한다:
> ```bash
> kubectl -n argocd rollout restart deploy/argocd-repo-server
> ```

---

## 복호화 검증 / 트러블슈팅 (Task 4-2)

런타임 인프라는 ansible 이 담당하므로, 실제 검증은 클러스터에서 수행한다.

```bash
# age 키 Secret 존재 확인
kubectl get secret -n argocd sops-age

# repo-server 가 복호화 중 에러를 내지 않는지 (KSOPS/age 관련 로그)
kubectl logs -n argocd deploy/argocd-repo-server

# *.sops.yaml 로 배포한 Secret 이 클러스터에 실제 생성됐는지
kubectl get secret -A
```

**복호화 실패 시 확인 위치**
- `argocd-repo-server` 파드 로그 — `ksops`/`sops`/`age` 관련 에러(키 불일치, 키 미마운트 등)
- `kubectl describe application <name> -n argocd` 의 `Conditions`/`Message` — sync 단계 실패 사유
- 흔한 원인: `.sops.yaml` 의 공개키와 `sops-age` 의 private key 불일치(키 회전 누락),
  `SOPS_AGE_KEY_FILE` 경로/마운트 문제.

> Git 에는 항상 암호문(`ENC[...]`)만 남고, 평문 Secret 은 클러스터 안에서만 존재한다.
