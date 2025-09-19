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

# Install or upgrade External DNS in the cluster
#
# Args:
#  - Cloudflare API token (required)
install_external_dns(){
  local cloudflare_api_token="$1"

  if [[ -z "$cloudflare_api_token" ]]; then
    fatal "Cloudflare API token is required as the first argument."
  fi

  external_dns_version="1.19.0"

  log "Installing External DNS version ${external_dns_version}"

  # Add the Kubernetes sigs repository
  helm repo add external-dns https://kubernetes-sigs.github.io/external-dns/
  helm repo update

  # Create the namespace for External DNS if it doesn't exist
  debug "Creating namespace for External DNS..."
  if ! kubectl get namespace external-dns &> /dev/null; then
    kubectl create namespace external-dns
  fi

  # Create secret for Cloudflare API token
  debug "Creating secret for Cloudflare API token..."
  if ! kubectl get secret cloudflare-api-key -n external-dns &> /dev/null; then
    kubectl create secret generic cloudflare-api-key \
      --from-literal="apiKey=${cloudflare_api_token}" \
      -n external-dns
  fi

  # Create the Helm values file for External DNS
  cat <<EOF | tee /tmp/external-dns-values.yaml
provider:
  name: cloudflare
env:
  - name: CF_API_TOKEN
    valueFrom:
      secretKeyRef:
        name: cloudflare-api-key
        key: apiKey
EOF

  # Install or upgrade External DNS using Helm
  if helm status external-dns -n external-dns &> /dev/null; then
    log "Upgrading existing External DNS installation..."
    helm upgrade external-dns external-dns/external-dns \
      --namespace external-dns \
      --version "${external_dns_version}" \
      -f /tmp/external-dns-values.yaml
  else
    log "Installing new External DNS installation..."
    helm install external-dns external-dns/external-dns \
      --namespace external-dns \
      --version "${external_dns_version}" \
      -f /tmp/external-dns-values.yaml
  fi

  log "External DNS installation complete."
}