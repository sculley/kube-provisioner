#!/usr/bin/env bash

log() {
  local msg="$*"
  printf '\033[1;32m[INFO]\033[0m %s\n' "$msg"
}
debug() {
  [[ "${DEBUG:-}" == "true" ]] || return 0
  local msg="$*"
  printf '\033[1;34m[DEBUG]\033[0m %s\n' "$msg"
}
warn() {
  local msg="$*"
  printf '\033[1;33m[WARN]\033[0m %s\n' "$msg"
}
err() {
  local msg="$*"
  printf '\033[1;31m[ERR ]\033[0m %s\n' "$msg" >&2
}
fatal() {
  local msg="$*"
  printf '\033[1;31m[FATAL]\033[0m %s\n' "$msg" >&2
  exit 1
}

# setup_kube_repo sets up the Kubernetes apt repository for a given version
#
# Arguments:
#  - $1 - The full Kubernetes version (e.g. 1.34.0)
_setup_kube_repo() {
    log "Setting up Kubernetes apt repository..."

    # This variable is set from the functions first argument
    local K8S_FULL_VERSION="${1:-}"
    # This variable is the major.minor version (e.g. 1.34)
    local K8S_MAJOR_MINOR_VERSION="${K8S_FULL_VERSION%.*}"

    # Ensure the keyrings directory exists
    sudo install -d -m 0755 /etc/apt/keyrings

    # Download and add the GPG key for the Kubernetes apt repository
    local key_url="https://pkgs.k8s.io/core:/stable:/v${K8S_MAJOR_MINOR_VERSION}/deb/Release.key"
    curl -fsSL "$key_url" | sudo gpg --batch --yes --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg

    # Add the Kubernetes apt repository
    echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v${K8S_MAJOR_MINOR_VERSION}/deb/ /" \
    | sudo tee /etc/apt/sources.list.d/kubernetes.list >/dev/null

    # Update package lists
    sudo apt-get update -y
}