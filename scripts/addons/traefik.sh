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

install_traefik() {
    local traefik_version="37.1.1"
    log "Installing Traefik version ${traefik_version}"

    # Add the Traefik Helm repository
    helm repo add traefik https://helm.traefik.io/traefik
    helm repo update

    # Create the traefik namespace if it doesn't exist
    if ! kubectl get namespace traefik &> /dev/null; then
        kubectl create namespace traefik
    fi

    # Install or upgrade Traefik using Helm
    if helm status traefik -n traefik &> /dev/null; then
        log "Upgrading existing Traefik installation..."
        helm upgrade traefik traefik/traefik \
            --namespace traefik \
            --version "${traefik_version}"
    else
        log "Installing new Traefik installation..."
        helm install traefik traefik/traefik \
            --namespace traefik \
            --version "${traefik_version}"
    fi

    log "Traefik installation complete."
}