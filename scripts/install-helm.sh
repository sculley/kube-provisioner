#!/usr/bin/env bash
set -euo pipefail

# shellcheck disable=SC1090,SC1091
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

install_helm() {
    debug "Installing Helm..."

    local helm_version
    local helm_url="https://api.github.com/repos/helm/helm/releases"

    helm_version=$(curl -sSL "$helm_url/latest" | jq -r '.tag_name')

    log "Installing Helm version ${helm_version}"

    local download_url="https://get.helm.sh/helm-${helm_version}-linux-amd64.tar.gz"

    curl -fsSL "$download_url" -o "/tmp/helm.tar.gz"
    tar -xzf /tmp/helm.tar.gz -C /tmp
    sudo mv /tmp/linux-amd64/helm /usr/local/bin/helm
    rm -rf /tmp/helm.tar.gz /tmp/linux-amd64

    log "Helm installed successfully."
}