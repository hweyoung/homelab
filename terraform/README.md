# Terraform — Proxmox VM provisioning (Rocky Linux)

Provisions the 4 homelab VMs on a single Proxmox node from a Rocky Linux
cloud-init template, using `telmate/proxmox` 3.0.x.

| VM | vCPU | RAM | Disk | Static IP | 역할 |
|---|---|---|---|---|---|
| bastion | 2 | 2GB | 20GB | .10 | 점프 호스트 |
| k8s-master | 2 | 4GB | 40GB | .11 | Control Plane |
| k8s-worker-1 | 4 | 24GB | 200GB | .12 | pool=prod |
| k8s-worker-2 | 4 | 24GB | 150GB | .13 | pool=dev |

## Prerequisites

### 1. A Proxmox API token

```bash
# on the Proxmox host
pveum user add terraform@pve                          # create the user (no password needed)
pveum user token add terraform@pve tf --privsep 0     # create token "tf"
#   -> prints the secret ONCE. Copy it into terraform.tfvars (pm_api_token_secret).
#   token id becomes:  terraform@pve!tf

# grant permissions (whole datacenter shown; scope down if you prefer)
pveum aclmod / -user terraform@pve -role PVEVMAdmin
```

> `--privsep 0` lets the token inherit the user's privileges. With `--privsep 1`
> you must grant the ACL to the **token** specifically (`-token 'terraform@pve!tf'`).

### 2. A Rocky Linux 9 cloud-init template named `Rocky-9-Template`

```bash
# on the Proxmox host
cd /var/lib/vz/template/iso
wget https://download.rockylinux.org/pub/rocky/9/images/x86_64/Rocky-9-GenericCloud-Base.latest.x86_64.qcow2

qm create 9000 --name Rocky-9-Template --memory 2048 --cores 2 --net0 virtio,bridge=vmbr0
qm importdisk 9000 Rocky-9-GenericCloud-Base.latest.x86_64.qcow2 local-lvm
qm set 9000 --scsihw virtio-scsi-pci --scsi0 local-lvm:vm-9000-disk-0
qm set 9000 --ide2 local-lvm:cloudinit          # <-- cloud-init drive (REQUIRED)
qm set 9000 --boot order=scsi0
qm set 9000 --serial0 socket --vga serial0
# optional but recommended so qemu_agent=1 works later:
# (install qemu-guest-agent inside the image, or via cloud-init)
qm template 9000
```

> The cloud-init drive (`ide2`) on the template is **required** — this config
> sets `ipconfig0/ciuser/sshkeys` but does not create the cloud-init disk
> itself. The clone inherits it from the template.

## Usage

```bash
cp terraform.tfvars.example terraform.tfvars
# edit terraform.tfvars: API URL, password, SSH key, subnet/gateway

terraform init
terraform plan
terraform apply
```

Get the Ansible inventory for the next step (Tailscale role etc.):

```bash
terraform output -raw ansible_inventory
```

## Notes

- **Secrets**: `terraform.tfvars` and state are gitignored. Auth uses an API
  token (scopable and easy to revoke). The token secret still lands in the
  state file, so consider an encrypted/remote backend for state.
- **qemu_agent**: leave at `0` unless the template has the guest agent, or
  `apply` will hang. With it enabled, Terraform can report live IPs.
- **CPU block**: kept to `cores` only to match the schema you validated on the
  RC provider. Add `sockets`/`type` if your build accepts them.
- **Static IPs** are used so k8s node IPs never change. Set `ip = "dhcp"` in a
  VM entry to opt out.
