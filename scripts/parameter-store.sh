#!/usr/bin/env bash
set -euo pipefail

# shellcheck disable=SC1090,SC1091
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

# Install AWS CLI if not already installed
_install_aws_cli() {
    if ! command -v aws &> /dev/null; then
        log "Installing AWS CLI..."
        local aws_cli_url="https://awscli.amazonaws.com/\
awscli-exe-linux-x86_64.zip"
        curl -fsSL "$aws_cli_url" -o "/tmp/awscliv2.zip"
        # ensure unzip is available
        if ! command -v unzip &> /dev/null; then
            sudo apt-get update -y >/dev/null
            sudo apt-get install -y unzip >/dev/null
        fi
        unzip -q /tmp/awscliv2.zip -d /tmp
        sudo /tmp/aws/install
        rm -rf /tmp/aws /tmp/awscliv2.zip
        log "AWS CLI installed successfully."
    else
        log "AWS CLI is already installed."
    fi
}

# Retrieve kubeadm parameters needed for worker nodes to join the cluster
# Returns a JSON object with the following fields:
#  - address: The control plane node address
#  - token: The kubeadm join token
#  - cert_hash: The certificate hash
#  - cert_key: The certificate key for joining the cluster
_get_kubeadm_parameters() {
    local join_command
    join_command=$(kubeadm token create --print-join-command)

    local address token cert_hash cert_key
    address=$(echo "${join_command}" | awk '{print $3}' | cut -d: -f1)
    token=$(echo "${join_command}"   | awk '{print $5}')
    cert_hash=$(echo "${join_command}" | awk '{print $7}' | cut -d: -f2)
    cert_key=$(kubeadm init phase upload-certs --upload-certs | tail -n1)

    if [[ -z "${token}" || -z "${cert_hash}" || -z "${cert_key}" ]]; then
        fatal "Failed to retrieve kubeadm parameters."
    fi

    jq -n \
        --arg address "$address" \
        --arg token "$token" \
        --arg cert_hash "$cert_hash" \
        --arg cert_key "$cert_key" \
        '{
            "address": $address,
            "token": $token,
            "cert_hash": $cert_hash,
            "cert_key": $cert_key
        }'
}

# Load environment variables from a JSON string with a given prefix
#
# Args:
#  - json: The JSON string to parse
#  - prefix: The prefix to add to each environment variable
_load_env_from_json_str() {
  local json="$1" prefix="$2"
  eval "$(
    jq -r --arg prefix "$prefix" '
      def norm: gsub("[^A-Za-z0-9]"; "_") | ascii_upcase;
      paths(scalars) as $p
      | ([ $p[] | tostring | norm ] | join("_")) as $name
      | "export \($prefix + "_" + $name)=\((getpath($p)) | @sh)"
    ' <<< "$json"
  )"
}

# Store cluster parameters to S3
#
# Args:
#  - cluster_id: The unique identifier for the cluster
store_parameters() {
    local cluster_id=$1
    local parameters
    parameters="$(_get_kubeadm_parameters)"

    # Install AWS CLI if not present
    _install_aws_cli

    local s3_path="s3://someadmin-cloud-parameter-store-dev/\
${cluster_id}/parameters"
    log "Storing parameters for cluster ID ${cluster_id} to S3: ${s3_path}"

    # Get the kubeadm parameters and write them to S3
    echo "${parameters}" | \
    aws s3 cp - "${s3_path}" --acl private
}

# Retrieve cluster parameters from S3 and export them as environment variables
# Args:
#  - cluster_id: The unique identifier for the cluster
retrieve_parameters() {
    local cluster_id=$1
    local parameters

    # Install AWS CLI if not present
    _install_aws_cli

    local s3_path="s3://someadmin-cloud-parameter-store-dev/\
${cluster_id}/parameters"

    log "Retrieving parameters for cluster ID ${cluster_id} \
from S3: ${s3_path}"

    # Retrieve the parameters from S3 and store them in the 'parameters' 
    # variable
    parameters=$(aws s3 cp "${s3_path}" -)

    # Check if parameters were retrieved successfully
    if [[ -z "${parameters}" ]]; then
        fatal "No parameters found for cluster ID ${cluster_id}."
    fi

    # Export the parameters as environment variables (expects JSON)
    _load_env_from_json_str "${parameters}" "KUBE_PROVISION"
}

# Create a cronjob to back up parameters every 6 hours
# Args:
#  - cluster_id: The unique identifier for the cluster
create_parameter_store_cronjob() {
    local cluster_id=$1

    log "Creating parameter store cronjob to back up \
parameters every 6 hours..."

    cat <<EOF >/etc/cron.d/parameter-store-backup
# m h dom mon dow user command
0 */6 * * * root /root/kube-deploy/scripts/parameter-store.sh ${cluster_id}\
>> /var/log/parameter-store-backup.log 2>&1
EOF

    log "Setting up log rotation for parameter store backup logs..."

    # Create a logrotate configuration to rotate the log file weekly
    # and keep 4 weeks of logs
    cat <<EOF >/etc/logrotate.d/parameter-store-backup
/var/log/parameter-store-backup.log {
    weekly
    rotate 4
    compress
    missingok
    notifempty
    create 0640 root root
}
EOF
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    cluster_id="$1"

    log "Storing parameters for cluster ID ${cluster_id}..."

    # Store the parameters in the parameter store
    store_parameters "${cluster_id}"

    log "Parameter store setup complete."
fi