.PHONY: all prepare sync-kubespray inventory syntax ssh-check bootstrap vault \
        bastion-ssh bastion-hosts tailscale kubespray post-kubespray helm \
        helm-upgrade-precheck helm-upgrade helm-upgrade-major helm-upgrade-postcheck \
        sops argocd \
        kubernetes-upgrade-precheck kubernetes-upgrade kubernetes-upgrade-postcheck \
        argocd-upgrade-precheck argocd-upgrade argocd-upgrade-reconcile \
        argocd-upgrade-postcheck

BOOTSTRAP_PLAYBOOK := playbooks/bootstrap.yml
UPGRADE_PLAYBOOK := playbooks/upgrade.yml

# 기본 타깃: 컨트롤러 준비 → 인벤토리 점검 → syntax-check → tailscale → 전체 부트스트랩
all: prepare inventory syntax tailscale bootstrap

prepare:
	./scripts/prepare-bastion.sh

sync-kubespray:
	./scripts/sync-kubespray.sh

inventory:
	./scripts/run-inventory.sh --graph

syntax:
	./scripts/run-ansible.sh $(BOOTSTRAP_PLAYBOOK) --syntax-check
	./scripts/run-ansible.sh $(UPGRADE_PLAYBOOK) --syntax-check

ssh-check:
	./scripts/run-adhoc.sh k8s_cluster -m ping

# secrets.yml 편집 (인자 생략 시 edit). 예: make vault ARGS=view
vault:
	./scripts/run-vault.sh $(ARGS)

bootstrap: sync-kubespray ssh-check
	./scripts/run-playbook.sh bootstrap $(BOOTSTRAP_PLAYBOOK) -e @secrets.yml --ask-vault-pass

# 개별 단계 (tag 기반)
bastion-ssh:
	./scripts/run-playbook.sh bastion-ssh $(BOOTSTRAP_PLAYBOOK) --tags bastion_ssh

bastion-hosts:
	./scripts/run-playbook.sh bastion-hosts $(BOOTSTRAP_PLAYBOOK) --tags bastion_hosts

tailscale:
	./scripts/run-playbook.sh tailscale $(BOOTSTRAP_PLAYBOOK) --tags tailscale -e @secrets.yml --ask-vault-pass

kubespray: sync-kubespray ssh-check
	./scripts/run-playbook.sh kubespray $(BOOTSTRAP_PLAYBOOK) --tags kubespray

post-kubespray:
	./scripts/run-playbook.sh post-kubespray $(BOOTSTRAP_PLAYBOOK) --tags post_kubespray

helm:
	./scripts/run-playbook.sh helm $(BOOTSTRAP_PLAYBOOK) --tags helm

helm-upgrade-precheck: ssh-check
	./scripts/run-playbook.sh helm-upgrade-precheck $(UPGRADE_PLAYBOOK) --tags helm_upgrade_precheck

helm-upgrade: ssh-check
	./scripts/run-playbook.sh helm-upgrade $(UPGRADE_PLAYBOOK) --tags helm_upgrade_run \
		-e helm_upgrade_confirm=true

helm-upgrade-major: ssh-check
	./scripts/run-playbook.sh helm-upgrade-major $(UPGRADE_PLAYBOOK) --tags helm_upgrade_run \
		-e helm_upgrade_confirm=true -e helm_upgrade_allow_major=true

helm-upgrade-postcheck: ssh-check
	./scripts/run-playbook.sh helm-upgrade-postcheck $(UPGRADE_PLAYBOOK) --tags helm_upgrade_postcheck \
		-e helm_upgrade_postcheck_only=true

sops:
	./scripts/run-playbook.sh sops $(BOOTSTRAP_PLAYBOOK) --tags sops -e @secrets.yml --ask-vault-pass

argocd:
	./scripts/run-playbook.sh argocd-install $(BOOTSTRAP_PLAYBOOK) --tags argocd \
		-e @secrets.yml --ask-vault-pass

kubernetes-upgrade-precheck: sync-kubespray ssh-check
	./scripts/run-playbook.sh kubernetes-upgrade-precheck $(UPGRADE_PLAYBOOK) --tags kubernetes_upgrade_precheck

kubernetes-upgrade: sync-kubespray ssh-check
	./scripts/run-playbook.sh kubernetes-upgrade $(UPGRADE_PLAYBOOK) --tags kubernetes_upgrade_run \
		-e kubernetes_upgrade_confirm=true

kubernetes-upgrade-postcheck: sync-kubespray ssh-check
	./scripts/run-playbook.sh kubernetes-upgrade-postcheck $(UPGRADE_PLAYBOOK) --tags kubernetes_upgrade_postcheck \
		-e kubernetes_upgrade_postcheck_only=true

argocd-upgrade-precheck: ssh-check
	./scripts/run-playbook.sh argocd-upgrade-precheck $(UPGRADE_PLAYBOOK) --tags argocd_upgrade_precheck

argocd-upgrade: ssh-check
	./scripts/run-playbook.sh argocd-upgrade $(UPGRADE_PLAYBOOK) --tags argocd_upgrade_run \
		-e argocd_upgrade_confirm=true

argocd-upgrade-reconcile: ssh-check
	./scripts/run-playbook.sh argocd-upgrade-reconcile $(UPGRADE_PLAYBOOK) --tags argocd_upgrade_run \
		-e argocd_upgrade_confirm=true -e argocd_upgrade_reconcile=true

argocd-upgrade-postcheck: ssh-check
	./scripts/run-playbook.sh argocd-upgrade-postcheck $(UPGRADE_PLAYBOOK) --tags argocd_upgrade_postcheck \
		-e argocd_upgrade_postcheck_only=true
