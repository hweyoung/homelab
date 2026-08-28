.PHONY: all prepare sync-kubespray inventory syntax ssh-check bootstrap vault \
        bastion-ssh bastion-hosts tailscale kubespray post-kubespray helm sops argocd \
        kubernetes-upgrade-precheck kubernetes-upgrade kubernetes-upgrade-postcheck

# 기본 타깃: 컨트롤러 준비 → 인벤토리 점검 → syntax-check → tailscale → 전체 부트스트랩
all: prepare inventory syntax tailscale bootstrap

prepare:
	./scripts/prepare-bastion.sh

sync-kubespray:
	./scripts/sync-kubespray.sh

inventory:
	./scripts/run-inventory.sh --graph

syntax:
	./scripts/run-ansible.sh playbooks/site.yml --syntax-check
	./scripts/run-ansible.sh playbooks/kubernetes/upgrade.yml --syntax-check

ssh-check:
	./scripts/run-adhoc.sh k8s_cluster -m ping

# secrets.yml 편집 (인자 생략 시 edit). 예: make vault ARGS=view
vault:
	./scripts/run-vault.sh $(ARGS)

bootstrap: sync-kubespray ssh-check
	./scripts/run-playbook.sh bootstrap playbooks/site.yml -e @secrets.yml --ask-vault-pass

# 개별 단계 (tag 기반)
bastion-ssh:
	./scripts/run-playbook.sh bastion-ssh playbooks/site.yml --tags bastion_ssh

bastion-hosts:
	./scripts/run-playbook.sh bastion-hosts playbooks/site.yml --tags bastion_hosts

tailscale:
	./scripts/run-playbook.sh tailscale playbooks/site.yml --tags tailscale -e @secrets.yml --ask-vault-pass

kubespray: sync-kubespray ssh-check
	./scripts/run-playbook.sh kubespray playbooks/site.yml --tags kubespray

post-kubespray:
	./scripts/run-playbook.sh post-kubespray playbooks/site.yml --tags post_kubespray

helm:
	./scripts/run-playbook.sh helm playbooks/site.yml --tags helm

sops:
	./scripts/run-playbook.sh sops playbooks/site.yml --tags sops -e @secrets.yml --ask-vault-pass

argocd:
	./scripts/run-playbook.sh argocd playbooks/site.yml --tags argocd -e @secrets.yml --ask-vault-pass

kubernetes-upgrade-precheck: sync-kubespray ssh-check
	./scripts/run-playbook.sh kubernetes-upgrade-precheck playbooks/kubernetes/upgrade.yml --tags precheck

kubernetes-upgrade: sync-kubespray ssh-check
	./scripts/run-playbook.sh kubernetes-upgrade playbooks/kubernetes/upgrade.yml --tags precheck,upgrade,postcheck \
		-e kubernetes_upgrade_confirm=true

kubernetes-upgrade-postcheck: sync-kubespray ssh-check
	./scripts/run-playbook.sh kubernetes-upgrade-postcheck playbooks/kubernetes/upgrade.yml --tags postcheck \
		-e kubernetes_upgrade_postcheck_only=true
