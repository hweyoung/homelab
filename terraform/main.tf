# ---------------------------------------------------------------------------
# Create all VMs from the var.vms map.
# Syntax follows telmate/proxmox 3.0.x (cpu block, disk slot/type, network id).
# ---------------------------------------------------------------------------
resource "proxmox_vm_qemu" "node" {
  for_each = var.vms

  name        = each.key
  vmid        = each.value.vmid
  target_node = var.target_node

  clone      = var.template_name
  full_clone = true
  os_type    = "cloud-init"
  agent      = var.qemu_agent

  memory   = each.value.memory
  tags     = each.value.tags
  scsihw   = "virtio-scsi-pci"
  bootdisk = "scsi0"

  # CPU — kept minimal to match the schema you validated.
  # You may add `sockets = 1` and `type = "host"` if your provider build accepts them.
  cpu {
    cores = each.value.cores
  }

  serial {
    id   = 0
    type = "socket"
  }

  vga {
    type   = "std"
    memory = 16
  }

  network {
    id     = 0
    model  = "virtio"
    bridge = var.network_bridge
  }

  disk {
    slot    = "scsi0"
    type    = "disk"
    storage = var.storage
    size    = each.value.disk
  }

  disk {
    slot    = "ide2"
    type    = "cloudinit"
    storage = var.storage
  }

  # --- Cloud-Init ---
  # Static IP per node (recommended for k8s so node IPs never change).
  # Set ip = "dhcp" in var.vms to fall back to DHCP.
  ipconfig0  = each.value.ip == "dhcp" ? "ip=dhcp" : "ip=${each.value.ip},gw=${var.gateway}"
  ciuser     = var.ci_user
  nameserver = var.nameserver
  sshkeys    = var.ssh_public_key

  # cloud-init / clone metadata can drift on re-reads; ignore to avoid noise.
  lifecycle {
    ignore_changes = [
      network,
      # disk,
    ]
  }
}
