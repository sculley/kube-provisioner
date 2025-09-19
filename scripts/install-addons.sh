#!/usr/bin/env bash

set -euo pipefail

# shellcheck disable=SC1090,SC1091
source "$(dirname "${BASH_SOURCE[0]}")/addons/metrics-server.sh"
# shellcheck disable=SC1090,SC1091
source "$(dirname "${BASH_SOURCE[0]}")/addons/kube-vip-controllor.sh"
# shellcheck disable=SC1090,SC1091
source "$(dirname "${BASH_SOURCE[0]}")/addons/traefik.sh"
# shellcheck disable=SC1090,SC1091
source "$(dirname "${BASH_SOURCE[0]}")/addons/external-dns.sh"
# shellcheck disable=SC1090,SC1091
source "$(dirname "${BASH_SOURCE[0]}")/addons/cert-manager.sh"
# shellcheck disable=SC1090,SC1091
source "$(dirname "${BASH_SOURCE[0]}")/addons/longhorn.sh"
# shellcheck disable=SC1090,SC1091
source "$(dirname "${BASH_SOURCE[0]}")/addons/argocd.sh"

# Waits for a specific Pod in a namespace to be ready
#
# Args:
#  - namespace: The namespace of the Pod
#  - pod: The name of the Pod
_wait_for_pod_ready() {
    local namespace="$1" pod="$2"
    
        log "Waiting for Pod ${pod} in namespace ${namespace} to be ready..."
        echo "Waiting for pod ${pod} in namespace ${namespace} to be ready..."
        kubectl wait --namespace "${namespace}" \
            --for=condition=Ready pod "${pod}" \
            --timeout=120s
}

install_addons() {
    local cloudflare_api_token="$1" letsencrypt_env="${2:-staging}"

    if [[ -z "$cloudflare_api_token" ]]; then
        fatal "Cloudflare API token is required to install external-dns and cert-manager"
    fi

    install_metrics_server
    install_kube_vip_controller
    install_traefik
    install_external_dns "$cloudflare_api_token"
    install_cert_manager "$cloudflare_api_token" "$letsencrypt_env"

    # wait for external-dns and cert-manager to be ready
    log "Waiting for external-dns and cert-manager to be ready..."
    _wait_for_pod_ready "external-dns" "external-dns"
    _wait_for_pod_ready "cert-manager" "cert-manager"

    install_longhorn
    install_argocd "$letsencrypt_env"
}