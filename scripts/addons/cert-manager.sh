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

# Create a ClusterIssuer resource for cert-manager using Cloudflare DNS01 challenge
#
# Args:
#  - name: Name of the ClusterIssuer (e.g., letsencrypt-prod)
#  - server: ACME server URL (e.g., https://acme-v02.api.letsencrypt.org/directory)
_create_cluster_issuer(){
  local name="$1" server="$2"

  debug "Creating ClusterIssuer ${name} with server ${server}"

  # Install the ClusterIssuer for Let's Encrypt
  cat <<EOF | kubectl apply -f -
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: ${name}
spec:
  acme:
    email: signups@samculley.co.uk
    server: ${server}
    privateKeySecretRef:
      name: ${name}
    solvers:
    - dns01:
        cloudflare:
          apiTokenSecretRef:
            name: cloudflare-api-key
            key: apiKey
EOF
}

install_cert_manager(){
  local cloudflare_api_token="$1" letsencrypt_env="${2:-staging}"

  if [[ -z "$cloudflare_api_token" ]]; then
    fatal "Cloudflare API token is required as the first argument."
  fi

  cert_manager_version="1.18.2"

  # Install the CustomResourceDefinitions and the cert-manager itself
  kubectl apply -f "https://github.com/cert-manager/cert-manager/releases/\
download/v${cert_manager_version}/cert-manager.crds.yaml"

  # Add the cert-manager helm repo
  helm repo add jetstack https://charts.jetstack.io --force-update

  # Install or upgrade cert-manager using Helm
  if helm status cert-manager -n cert-manager &> /dev/null; then
    log "Upgrading existing cert-manager installation..."
    helm upgrade cert-manager jetstack/cert-manager \
        --namespace cert-manager \
        --version "${cert_manager_version}" \
        --set installCRDs=false
  else
    log "Installing new cert-manager installation..."
    kubectl create namespace cert-manager || true
    helm install cert-manager jetstack/cert-manager \
        --namespace cert-manager \
        --version "${cert_manager_version}" \
        --set installCRDs=false
  fi

  # Wait for cert-manager pods to be ready
  log "Waiting for cert-manager pods to be ready..."
  kubectl wait --namespace cert-manager \
    --for=condition=Ready pods \
    --selector=app.kubernetes.io/instance=cert-manager \
    --timeout=180s
  log "cert-manager installation complete."

  # Create secret for Cloudflare API token
  if ! kubectl get secret cloudflare-api-key -n cert-manager &> /dev/null; then
    kubectl create secret generic cloudflare-api-key \
      --from-literal="apiKey=${cloudflare_api_token}" \
      -n cert-manager
  fi

  # Create the ClusterIssuer for Let's Encrypt production
  case "${letsencrypt_env}" in
    production)
      _create_cluster_issuer "letsencrypt-prod" "https://acme-v02.api.letsencrypt.org/directory"
      ;;
    staging)
      _create_cluster_issuer "letsencrypt-staging" "https://acme-staging-v02.api.letsencrypt.org/directory"
      ;;
    *)
      fatal "Invalid letsencrypt_env value: ${letsencrypt_env}. Must be 'production' or 'staging'."
      ;;
  esac

  log "ClusterIssuer 'letsencrypt-prod' created."
}