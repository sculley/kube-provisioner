#!/usr/bin/env bash
set -euo pipefail

# Resolve this script's directory (works regardless of CWD, symlinks not required)
SCRIPT_DIR="$(cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Try to source common.sh from likely locations
if [[ -f "${SCRIPT_DIR}/../common.sh" ]]; then
  # expected layout: scripts/common.sh
  #                  scripts/addons/metrics-server.sh  (this file)
  # shellcheck disable=SC1091
  source "${SCRIPT_DIR}/../common.sh"
elif [[ -f "${SCRIPT_DIR}/common.sh" ]]; then
  # fallback if you actually keep common.sh in addons/
  # shellcheck disable=SC1091
  source "${SCRIPT_DIR}/common.sh"
else
  echo "[ERR ] common.sh not found next to this script or one directory up" >&2
  exit 1
fi

install_kube_vip_controller() {
    local kube_vip_version
    local kube_api_url="https://api.github.com/repos/kube-vip/kube-vip/\
releases/latest"
    kube_vip_version=$(curl -sSL "$kube_api_url" | jq -r .tag_name)

    log "Installing kube-vip controller version ${kube_vip_version}"

    # Install the kube-vip cloud controller
    kubectl apply -f "https://raw.githubusercontent.com/kube-vip/kube-vip-\
cloud-provider/main/manifest/kube-vip-cloud-controller.yaml"

    # Create the kube-vip controllor dhcp range configmap
    debug "Creating kube-vip dhcp range configmap in kube-vip namespace"
    
    kubectl delete configmap -n kube-system kubevip --ignore-not-found
    kubectl create configmap -n kube-system kubevip \
        --from-literal=range-global="192.168.122.50-192.168.122.254"
 
    log "kube-vip controller installation complete."
}