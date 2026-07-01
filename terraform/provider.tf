terraform {
  required_providers {
    proxmox = {
      source  = "telmate/proxmox"
      version = "3.0.2-rc04"
    }
  }
}

provider "proxmox" {
  pm_api_url      = var.pm_api_url
  pm_tls_insecure = var.pm_tls_insecure

  # --- Auth: API token (recommended) ---
  # token id format: "user@realm!tokenname"  e.g. "terraform@pve!tf"
  pm_api_token_id     = var.pm_api_token_id
  pm_api_token_secret = var.pm_api_token_secret

  # --- Fallback: user/password (uncomment to use instead of a token) ---
  # pm_user     = var.pm_user
  # pm_password = var.pm_password
}
