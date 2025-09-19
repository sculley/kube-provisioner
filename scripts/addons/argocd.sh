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

install_argocd() {
    local argocd_version="8.3.9"
    debug "Installing ArgoCD version ${argocd_version}"

    local letsencrypt_env="${1:-staging}"

    case "${letsencrypt_env}" in
        production)
            letsencrypt_env="letsencrypt-prod"
            ;;
        staging|*)
            letsencrypt_env="letsencrypt-staging"
            ;;
    esac

    # Create the argocd namespace if it doesn't exist
    if ! kubectl get namespace argocd &> /dev/null; then
        kubectl create namespace argocd
    fi

    # Add the ArgoCD Helm repository
    helm repo add argo https://argoproj.github.io/argo-helm
    helm repo update

    local domain
    domain=$(hostname -d)

    if [[ -z "$domain" ]]; then
        fatal "Domain name could not be determined. Please ensure your system's hostname is set correctly."
    fi

    # Install or upgrade ArgoCD using Helm
    if helm status argocd -n argocd &> /dev/null; then
        log "Upgrading existing ArgoCD installation..."
        helm upgrade argocd argo/argo-cd \
            --namespace argocd \
            --version "${argocd_version}" \
            --set global.domain="argocd.${domain}" \
            --set server.service.type=ClusterIP \
            --set configs.params."server\.insecure"=true \
            --set server.ingress.enabled=true \
            --set server.ingress.hostname="argocd.${domain}" \
            --set server.ingress.annotations."cert-manager\.io/cluster-issuer"="${letsencrypt_env}" \
            --set server.ingress.tls.enabled=true \
            --set server.ingress.tls.extraHosts[0]="argocd.${domain}"
    else
        log "Installing new ArgoCD installation..."
        helm install argocd argo/argo-cd \
            --namespace argocd \
            --version "${argocd_version}" \
            --set global.domain="argocd.${domain}" \
            --set server.service.type=ClusterIP \
            --set configs.params."server\.insecure"=true \
            --set server.ingress.enabled=true \
            --set server.ingress.hostname="argocd.${domain}" \
            --set server.ingress.annotations."cert-manager\.io/cluster-issuer"="${letsencrypt_env}" \
            --set server.ingress.tls.enabled=true \
            --set server.ingress.tls.extraHosts[0]="argocd.${domain}"
    fi

    log "ArgoCD installation complete."
}