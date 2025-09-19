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

install_metrics_server() {
    local metrics_server_version="0.13.1"
    log "Installing metrics-server version ${metrics_server_version}"

    metrics_server_url="https://github.com/kubernetes-sigs/metrics-server/\
releases/latest/download/components.yaml"

    kubectl apply -n kube-system -f "${metrics_server_url}"

    log "Patching metrics-server deployment to add args for insecure TLS"
    kubectl -n kube-system patch deployment metrics-server \
        --type='json' \
        -p='[{"op": "add", "path": "/spec/template/spec/containers/0/args/-", "value": "--kubelet-insecure-tls"}]'
}