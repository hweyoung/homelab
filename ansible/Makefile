.PHONY: all prepare sync-kubespray inventory syntax ssh-check bootstrap vault \
        bastion-ssh bastion-hosts tailscale kubespray post-kubespray helm sops argocd

# 기본 타깃: 컨트롤러 준비 → 인벤토리 점검 → syntax-check → tailscale → 전체 부트스트랩
all: prepare inventory syntax tailscale bootstrap

prepare:
	./scripts/prepare-bastion.sh

sync-kubespray:
	./scripts/sync-kubespray.sh

inventory:
	./scripts/run-inventory.sh --graph

syntax:
	./scripts/run-ansible.sh site.yml --syntax-check

ssh-check:
	./scripts/run-adhoc.sh k8s_cluster -m ping

# secrets.yml 편집 (인자 생략 시 edit). 예: make vault ARGS=view
vault:
	./scripts/run-vault.sh $(ARGS)

bootstrap: sync-kubespray ssh-check
	./scripts/run-ansible.sh site.yml -e @secrets.yml --ask-vault-pass

# 개별 단계 (tag 기반)
bastion-ssh:
	./scripts/run-ansible.sh site.yml --tags bastion_ssh

bastion-hosts:
	./scripts/run-ansible.sh site.yml --tags bastion_hosts

tailscale:
	./scripts/run-ansible.sh site.yml --tags tailscale -e @secrets.yml --ask-vault-pass

kubespray: sync-kubespray ssh-check
	./scripts/run-ansible.sh site.yml --tags kubespray

post-kubespray:
	./scripts/run-ansible.sh site.yml --tags post_kubespray

helm:
	./scripts/run-ansible.sh site.yml --tags helm

sops:
	./scripts/run-ansible.sh site.yml --tags sops -e @secrets.yml --ask-vault-pass

argocd:
	./scripts/run-ansible.sh site.yml --tags argocd
