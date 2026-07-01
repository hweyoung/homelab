# Summary of created VMs (IP comes from the static config in var.vms).
output "vms" {
  description = "Created VMs: name => { vmid, ip, role tags }"
  value = {
    for name, vm in var.vms : name => {
      vmid = vm.vmid
      ip   = vm.ip
      tags = vm.tags
    }
  }
}

# Ready-to-paste Ansible inventory (matches the tailscale role's [bastion] group).
output "ansible_inventory" {
  description = "Copy into your Ansible inventory"
  value = join("\n", concat(
    ["[bastion]"],
    [for name, vm in var.vms : "${name} ansible_host=${split("/", vm.ip)[0]} ansible_user=${var.ci_user}" if name == "bastion"],
    ["", "[k8s_master]"],
    [for name, vm in var.vms : "${name} ansible_host=${split("/", vm.ip)[0]} ansible_user=${var.ci_user}" if name == "k8s-master"],
    ["", "[k8s_workers]"],
    [for name, vm in var.vms : "${name} ansible_host=${split("/", vm.ip)[0]} ansible_user=${var.ci_user}" if length(regexall("^k8s-worker", name)) > 0],
  ))
}
