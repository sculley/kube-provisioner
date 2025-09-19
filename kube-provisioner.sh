#!/usr/bin/env bash

# kube-provision script
# This script provisions a High Availability Kubernetes cluster
# using kubeadm
# It uses kube-vip for the virtual IP and supports both control-plane
# and worker nodes and installs common add-ons required for a functional
# cluster.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# source the script files
# shellcheck disable=SC1090,SC1091
source "$SCRIPT_DIR/scripts/common.sh"
# shellcheck disable=SC1090,SC1091
source "$SCRIPT_DIR/scripts/install-containerd.sh"
# shellcheck disable=SC1090,SC1091
source "$SCRIPT_DIR/scripts/install-kubernetes.sh"
# shellcheck disable=SC1090,SC1091
source "$SCRIPT_DIR/scripts/configure-kubernetes.sh"
# shellcheck disable=SC1090,SC1091
source "$SCRIPT_DIR/scripts/install-helm.sh"
# shellcheck disable=SC1090,SC1091
source "$SCRIPT_DIR/scripts/install-addons.sh"


# Usage function to display help
usage() {
  cat <<EOF
Usage: $0 [options]

Options:
  --cluster-name, -c <name>           Specify the cluster name
  --role, -r <control-plane|worker>
    Specify the node role (default: control-plane)
  --method, -m <init|join>
    Specify the method to use (default: init)
  --k8s-version, -k <version>
    Specify the Kubernetes version (default: v1.34.0)
  --vip-address <IP_ADDRESS>
    Specify the VIP address for kube-vip (required if --type is ha)
  --add-ons-only                      Install or upgrade add-ons only
  --letsencrypt-environment <staging|production>
    Specify the Let's Encrypt environment to use (default: staging)
  --help, -h                          Show this help message and exit

Requires the following environment variables to be set to access AWS S3
for storing and retrieving kubeadm parameters:
  - AWS_ACCESS_KEY_ID
  - AWS_SECRET_ACCESS_KEY
  - AWS_REGION
EOF
}

# Parse command line arguments
while [[ $# -gt 0 ]]; do
  case "$1" in
    --cluster-name|-c)
      cluster_name="$2"; shift 2 ;;
    --role|-r)
      role="$2"; shift 2 ;;
    --method|-m)
      method="$2"; shift 2 ;;
    --k8s-version|-k)
      k8s_version="$2"; shift 2 ;;
    --vip-address)
      vip_address="$2"; shift 2 ;;
    --add-ons-only)
      add_ons_only=true; shift ;;
    --cloudflare-api-token)
      cloudflare_api_token="$2"; shift 2 ;;
    --letsencrypt-environment)
      letsencrypt_environment="$2"; shift 2 ;;
    --help|-h)
      usage; exit 0 ;;
    --) shift; break ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

# Validate required arguments
# Cluster name is required
if [[ "${cluster_name:-}" == "" ]]; then
  fatal "--cluster-name is required"
fi

# Must be control-plane or worker
if [[ "${role:-}" != "control-plane" && "${role:-}" != "worker" ]]; then
  fatal "Invalid role specified, must be 'control-plane' or 'worker'"
fi

# Method must be init or join
if [[ "${method:-}" != "init" && "${method:-}" != "join" ]]; then
  fatal "Invalid method specified, must be 'init' or 'join'"
fi

# Default Kubernetes version if not specified
if [[ -z "${k8s_version:-}" ]]; then
  fatal "No Kubernetes version specified, can't continue..."
fi

# Must match: number.number.number (e.g. 1.34.1)
if [[ ! "${k8s_version}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  fatal "Invalid Kubernetes version specified, must be in \
         format X.Y.Z (e.g. 1.34.1)"
fi

# If role is control-plane, vip-address is required
if [[ "${role}" == "control-plane" ]]; then
  if [[ -z "${vip_address:-}" ]]; then
    fatal "--vip-address is required when role is \
           'control-plane'"
  fi
fi

if [[ "${cloudflare_api_token:-}" == "" ]]; then
  fatal "--cloudflare-api-token is required to install external-dns/cert-manager add-ons"
fi

# Default Let's Encrypt environment if not specified
if [[ -z "${letsencrypt_environment:-}" ]]; then
  letsencrypt_environment="staging"
fi

# If aws_access_key_id is not supplied, look for it in the environment 
# variable AWS_ACCESS_KEY_ID
if [[ -z "${AWS_ACCESS_KEY_ID:-}" ]] && \
   [[ -z "${AWS_SECRET_ACCESS_KEY:-}" ]] && \
   [[ -z "${AWS_REGION:-}" ]]; then
  fatal "AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY, and AWS_REGION environment \
variables must be set to store/retrieve kubeadm parameters"
fi

# Ensure aws_* variables are defined (may be provided via CLI flags 
# in other versions)
# Prefer explicit variables if already set; otherwise fall back to 
# environment variables.
aws_access_key_id="${aws_access_key_id:-${AWS_ACCESS_KEY_ID:-}}"
aws_secret_access_key="${aws_secret_access_key:-${AWS_SECRET_ACCESS_KEY:-}}"
aws_region="${aws_region:-${AWS_REGION:-}}"

# Install addons only if specified and exit
if [[ "${add_ons_only:-}" == "true" ]]; then
  log "Installing or upgrading add-ons only..."

  # Install Helm
  install_helm

  install_addons "$cloudflare_api_token"

  # Exit after installing add-ons
  exit 0
fi

# Install containerd
install_containerd

# Install the kubernetes dependencies and packages
install_kubernetes "${k8s_version}"

# Configure the kubernetes cluster i.e. init/join and networking
configure_kubernetes \
  "${cluster_name}" \
  "${role}" \
  "${method}" \
  "${vip_address}"

if [[ "${method}" == "init" ]]; then
  # Install Helm
  install_helm

  # Install or upgrade add-ons
  install_addons "$cloudflare_api_token"
fi

log "Kubernetes provisioning complete."

