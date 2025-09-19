#!/usr/bin/env bash

# kube-provision script
# This script provisions a High Availability Kubernetes cluster
# using kubeadm
# It uses kube-vip for the virtual IP and supports both control-plane
# and worker nodes and installs common add-ons required for a functional
# cluster.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# source the script files
# shellcheck disable=SC1090,SC1091
source "$ROOT_DIR/scripts/common.sh"
# shellcheck disable=SC1090,SC1091
source "$ROOT_DIR/scripts/install-containerd.sh"
# shellcheck disable=SC1090,SC1091
source "$ROOT_DIR/scripts/install-kubernetes.sh"
# shellcheck disable=SC1090,SC1091
source "$ROOT_DIR/scripts/configure-kubernetes.sh"
# shellcheck disable=SC1090,SC1091
source "$ROOT_DIR/scripts/install-helm.sh"
# shellcheck disable=SC1090,SC1091
source "$ROOT_DIR/scripts/install-addons.sh"


# Usage function to display help
usage() {
  cat <<EOF
Usage: $0 [options]

Options:
  --install                                  Install Kubernetes (default: true)
  --upgrade                                  Upgrade Kubernetes (default: false)
  --cluster-name <name>                      Specify the cluster name (required)
  --role <control-plane|worker>              Specify the node role (default: control-plane)
  --method <init|join>                       Specify the method to use (default: init)
  --k8s-version <version>                    Specify the Kubernetes version (default: v1.34.0)
  --vip-address <IP_ADDRESS>                 Specify the VIP address for kube-vip (required)
  --add-ons-only                             Install or upgrade add-ons only (default: false)
  --letsencrypt-env <staging|production>     Specify the Let's Encrypt environment to use (default: staging)
  --cloudflare-api-token <token>             Specify the Cloudflare API token (required for init method on control-plane)
  --parameter-store-bucket <bucket_name>     Specify the S3 bucket name for parameter store (required)
  --aws-access-key-id <key_id>               AWS Access Key ID for S3 access (can also be set via AWS_ACCESS_KEY_ID env var)
  --aws-secret-access-key <secret_key>       AWS Secret Access Key for S3 access (can also be set via AWS_SECRET_ACCESS_KEY env var)
  --aws-region <region>                      AWS Region for S3 access (can also be set
  --help, -h                                 Show this help message and exit

Requires the following environment variables to be set to access AWS S3
for storing and retrieving kubeadm parameters:
  - AWS_ACCESS_KEY_ID
  - AWS_SECRET_ACCESS_KEY
  - AWS_REGION
EOF
}

# Default values for variables
install=false
upgrade=false

# Parse command line arguments
while [[ $# -gt 0 ]]; do
  case "$1" in
    --install)
      install=true; shift ;;
    --upgrade)
      upgrade=true; shift ;;
    --cluster-name|-c)
      cluster_name="$2"; shift 2 ;;
    --role)
      role="$2"; shift 2 ;;
    --method)
      method="$2"; shift 2 ;;
    --k8s-version)
      k8s_version="$2"; shift 2 ;;
    --vip-address)
      vip_address="$2"; shift 2 ;;
    --add-ons-only)
      add_ons_only=true; shift ;;
    --letsencrypt-environment)
      letsencrypt_environment="$2"; shift 2 ;;
    --cloudflare-api-token)
      cloudflare_api_token="$2"; shift 2 ;;
    --parameter-store-bucket)
      parameter_store_bucket="$2"; shift 2 ;;
    --aws-access-key-id)
      aws_access_key_id="$2"; shift 2 ;;
    --aws-secret-access-key)
      aws_secret_access_key="$2"; shift 2 ;;
    --aws-region)
      aws_region="$2"; shift 2 ;;
    --help|-h)
      usage; exit 0 ;;
    --) shift; break ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

if [[ "${install}" == "true" && "${upgrade}" == "true" ]]; then
  warn "Both --install and --upgrade specified, defaulting to --install"
  upgrade=false
fi

if [[ "${install}" == "false" && "${upgrade}" == "false" ]]; then
  install=true
  upgrade=false
fi

# Validate required arguments
# Cluster name is required
if [[ "${cluster_name:-}" == "" ]]; then
  fatal "--cluster-name is required"
fi

# upgrade should be true or false, if not set, default to false
if [[ "${upgrade:-}" == "" ]]; then
  upgrade="false"
elif [[ "${upgrade:-}" != "true" && "${upgrade:-}" != "false" ]]; then
  fatal "--upgrade must be true or false"
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

# cloudflare_api_token is required if method is init and role is control-plane
if [[ "${method}" == "init" && "${role}" == "control-plane" ]]; then
  if [[ -z "${cloudflare_api_token:-}" ]]; then
    fatal "--cloudflare-api-token is required when method is \
'init' and role is 'control-plane'"
  fi
fi

# Default Let's Encrypt environment if not specified
if [[ -z "${letsencrypt_environment:-}" ]]; then
  letsencrypt_environment="staging"
fi

# parameter_store_bucket is required
if [[ -z "${parameter_store_bucket:-}" ]]; then
  fatal "--parameter-store-bucket is required"
fi

# If aws_access_key_id, aws_secret_access_key, or aws_region are not set,
# check for the corresponding environment variables
if [[ -z "${aws_access_key_id:-}" || -z "${aws_secret_access_key:-}" || -z "${aws_region:-}" ]]; then
  if [[ -z "${AWS_ACCESS_KEY_ID:-}" || -z "${AWS_SECRET_ACCESS_KEY:-}" || -z "${AWS_REGION:-}" ]]; then
    fatal "AWS credentials and region must be provided via \
command line arguments or environment variables"
  else
    aws_access_key_id="${AWS_ACCESS_KEY_ID}"
    aws_secret_access_key="${AWS_SECRET_ACCESS_KEY}"
    aws_region="${AWS_REGION}"
  fi
fi

# Install/Upgrade the addons only if specified and exit
if [[ "${add_ons_only:-}" == "true" ]]; then
  log "Installing or upgrading add-ons only..."

  # Install Helm
  install_helm

  install_addons "$cloudflare_api_token"

  # Exit after installing add-ons
  exit 0
fi

# Start the installation or upgrade process
if [[ "${install}" == "true" ]]; then
  log "Starting Installation of Kubernetes for cluster: ${cluster_name} \
as a ${role} node using method: ${method}..."

  # Install containerd
  install_containerd

  # Install the kubernetes dependencies and packages
  install_kubernetes "${k8s_version}"

  # Create the /opt/kube-provisioner/bin directory if it doesn't exist
  if [[ ! -d /opt/kube-provisioner/bin ]]; then
    sudo mkdir -p /opt/kube-provisioner/bin
  fi

  # Copy scripts to /opt/kube-provisioner/bin
  install -D -m 0755 "${ROOT_DIR}/scripts/common.sh" /opt/kube-provisioner/bin/common.sh
  install -D -m 0755 "${ROOT_DIR}/scripts/parameter-store.sh" /opt/kube-provisioner/bin/parameter-store

  # Setup the kube-provisioner environment file
  cat <<EOF >/etc/kube-provisioner.env
# AWS credentials for accessing S3 to store/retrieve kubeadm parameters
AWS_ACCESS_KEY_ID=${aws_access_key_id}
AWS_SECRET_ACCESS_KEY=${aws_secret_access_key}
AWS_REGION=${aws_region}
EOF

  # shellcheck disable=SC1091
  source /etc/kube-provisioner.env

  # Configure the kubernetes cluster i.e. init/join and networking
  configure_kubernetes \
    "${cluster_name}" \
    "${role}" \
    "${method}" \
    "${vip_address}" \
    "${parameter_store_bucket}"

  if [[ "${method}" == "init" ]]; then
    # Install Helm
    install_helm

    # Install or upgrade add-ons
    install_addons "$cloudflare_api_token"
  fi
elif [[ "${upgrade}" == "true" ]]; then
  log "Starting Upgrade of Kubernetes for cluster: ${cluster_name} \
as a ${role} node..."

  debug "This is a placeholder for future upgrade functionality"
else
  log "Neither --install nor --upgrade specified, nothing to do..."
  exit 0
fi

log "Kubernetes provisioning complete."