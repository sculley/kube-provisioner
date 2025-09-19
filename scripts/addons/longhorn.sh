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

install_longhorn() {
    local longhorn_version="1.9.1"
    debug "Installing Longhorn version ${longhorn_version}"

    # Create the longhorn-system namespace if it doesn't exist
    if ! kubectl get namespace longhorn-system &> /dev/null; then
        kubectl create namespace longhorn-system
    fi

    # Add the Longhorn Helm repository
    helm repo add longhorn https://charts.longhorn.io
    helm repo update

    local domain
    domain=$(hostname -d)

    if [[ -z "$domain" ]]; then
        fatal "Domain name could not be determined. Please ensure your system's hostname is set correctly."
    fi

    # Install or upgrade Longhorn using Helm
    if helm status longhorn -n longhorn-system &> /dev/null; then
        log "Upgrading existing Longhorn installation..."
        helm upgrade longhorn longhorn/longhorn \
            --namespace longhorn-system \
            --version "${longhorn_version}"
    else
        log "Installing Longhorn..."
        helm install longhorn longhorn/longhorn \
            --namespace longhorn-system \
            --version "${longhorn_version}"
    fi

    # Create the RWX StorageClass if it doesn't exist
    if ! kubectl get storageclass longhorn-rwx &> /dev/null; then
        log "Creating RWX StorageClass for Longhorn..."
        cat <<EOF | kubectl apply -f -
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: longhorn-rwx
provisioner: driver.longhorn.io
allowVolumeExpansion: true
reclaimPolicy: Retain
volumeBindingMode: Immediate
parameters:
  numberOfReplicas: "2"
  staleReplicaTimeout: "2880"
  fsType: "ext4"
  nfsOptions: "vers=4.2,noresvport,softerr,timeo=600,retrans=5,rw,hard"
EOF
    else
        log "RWX StorageClass for Longhorn already exists."
    fi

    log "Longhorn installation complete."
}