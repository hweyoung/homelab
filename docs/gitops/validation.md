# GitOps 검증 (CI)

`gitops/**`를 바꾸는 PR은 `.github/workflows/gitops-validate.yml`이 정적으로 검사한다.
Argo CD는 merge 후 sync 시점에야 렌더 오류를 드러내므로, 같은 렌더를 PR 단계로 앞당기고
Secret 유출을 막는 것이 목적이다. 경로는 하드코딩하지 않고 `Chart.yaml`,
`kustomization.yaml`, root-app 렌더 결과에서 자동 탐색한다.

## 검사 항목

| 단계 | 확인 | 막는 문제 |
| --- | --- | --- |
| Helm template | 레포 내부 chart(root-app, namespaces) 렌더 | root-app의 `required`/`fail` 가드(versionRef, syncPolicyRef, path 누락) |
| Kustomize build | 모든 Kustomization build (KSOPS generator 제외) | 잘못된 resource/patch 경로, base 참조 오류 |
| Argo CD Application check | root-app이 렌더한 Application의 `path`, `valuesPath` 존재 여부와 원격 chart 렌더 | 경로 오타, chart 업그레이드 시 values 비호환 |
| SOPS encryption check | `*.sops.yaml`에 `sops:` 블록 존재 | 암호화하지 않은 Secret 커밋 |
| Plaintext secret scan | `kind: Secret` 매니페스트, 값이 붙은 민감 키 | 평문 Secret 커밋 |
| Placeholder residue check | `CHANGE_ME`, `REPLACE_ME` 등 | placeholder 그대로 배포 |
| Forbidden files check | kubeconfig, private key, `.env` 등 | 자격 증명 파일 커밋 |

같은 ref에 새 push가 오면 이전 실행은 `concurrency`로 취소된다.

## 설계 메모

### KSOPS는 generator를 빼고 build한다

KSOPS generator는 age key가 있어야 복호화되는데 CI에는 key를 두지 않는다. 그래서 `gitops`를
`$RUNNER_TEMP`에 복사하고 복사본의 `kustomization.yaml`에서 `generators`를 지운 뒤 build한다.
나머지 resource와 patch 구조는 그대로 검증되고, Secret 쪽은 SOPS 검사가 암호화 여부만 본다.
generator가 만드는 Secret 내용은 CI에서 검증되지 않는다.

현재 `generators`는 모두 KSOPS다. KSOPS가 아닌 generator를 추가하면 이 단계에서도 함께
빠지므로 검사 방식을 다시 정해야 한다.

### 원격 chart는 Argo CD와 같은 입력으로 렌더한다

root-app을 `helm template`으로 렌더하고, multi-source Application의 `sources[0]`
(chart, repoURL, targetRevision, `helm.skipCrds`)와 `$values/` valueFiles로 원격 chart를
렌더한다. `platformVersions.activeVersion`을 올릴 때 values 키가 바뀌어 깨지는 경우를 merge
전에 잡는 것이 핵심이다. repoURL에 scheme이 없으면(`ghcr.io/akuity/kargo-charts`) OCI로
간주해 `oci://`를 붙인다.

렌더만 확인하므로 AppProject whitelist 위반, CRD 존재 여부, 실제 sync 결과는 보지 않는다.

### 평문 Secret 패턴

- `^kind: Secret$`처럼 줄 끝을 고정한다. 고정하지 않으면 ESO의 `kind: SecretStore`가 걸린다.
- 민감 키는 같은 줄에 값이 있을 때만 잡는다. CNPG `bootstrap.initdb.secret:`이나 Pod
  `volumes[].secret:`처럼 아래에 `name:`이 오는 참조 블록은 Secret 값이 아니다.

키 이름 기반 검사라 `apiKey: abc` 같은 다른 이름은 잡지 못한다. 범위를 넓히려면 gitleaks 같은
엔트로피 기반 스캐너가 필요하다.

## 알려진 실패

`gitops/apps/api-common/base/ghcr-secret-generator.sops.yaml`은 암호문이 아니라 KSOPS
generator 정의인데 이름이 `*.sops.yaml`이라 SOPS 검사에 걸린다. 같은 내용의
`ghcr-secret-generator.yaml`이 실제로 `kustomization.yaml`에서 참조되므로 중복 파일이다.
삭제하기 전까지 SOPS 단계는 실패한다.

## 로컬 재현

CI와 같은 검사를 로컬에서 돌릴 때:

```bash
helm template root-app gitops/clusters/homelab/root-app
kustomize build gitops/platform/gateway
```

KSOPS 경로는 age key와 plugin이 있으면 그대로 build할 수 있다.

```bash
kustomize build --enable-alpha-plugins --enable-exec gitops/platform/cloudflared
```

정적 검사 통과는 배포 성공을 뜻하지 않는다. merge 후 확인 절차는
[`gitops/README.md`](README.md)와 [GitOps 아키텍처](architecture.md)의
검증 경계를 참고한다.
