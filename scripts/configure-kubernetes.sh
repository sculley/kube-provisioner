#!/usr/bin/env bash
set -euo pipefail

# shellcheck disable=SC1090,SC1091
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
# shellcheck disable=SC1090,SC1091
source "$(dirname "${BASH_SOURCE[0]}")/parameter-store.sh"

# Returns the default IP address of the machine
_get_default_ip_address() {
    ip -j route | jq -r '.[] | select(.dst == "default") | .prefsrc'
}

# Returns the default network interface of the machine
_get_default_interface() {
    ip -j route | jq -r '.[] | select(.dst == "default") | .dev'
}

_setup_kube_config() {
    log "Setting up kubeconfig for kubectl..."

    debug "Creating /root/.kube directory"
    mkdir -p /root/.kube

    debug "Copying /etc/kubernetes/admin.conf to /root/.kube/config"
    sudo cp /etc/kubernetes/admin.conf /root/.kube/config
}

# Creates a static Pod manifest for kube-vip
# https://kube-vip.io/docs/installation/static/
#
# Args:
#  - vip_address: The virtual IP address to be used by kube-vip
#  - k8s_config_path: The path to the kubeconfig file
_create_kube_vip_static_pod_manifiest() {
    local vip_address="$1" k8s_config_path="$2"
    
    local kube_vip_version
    local kube_api_url="https://api.github.com/repos/kube-vip/kube-vip/\
releases/latest"
    kube_vip_version=$(curl -sSL "$kube_api_url" | jq -r .tag_name)
    
    local interface
    interface=$(_get_default_interface)
    
    log "Creating kube-vip static pod manifest with vip_address=${vip_address} \
k8s_config_path=${k8s_config_path} interface=${interface} \
kube_vip_version=${kube_vip_version}"

    debug "Pulling kube-vip image version ${kube_vip_version}"
    ctr image pull "ghcr.io/kube-vip/kube-vip:${kube_vip_version}"
    
    debug "Generating kube-vip manifest"
    local kube_vip_image="ghcr.io/kube-vip/kube-vip:${kube_vip_version}"
    ctr run --rm --net-host "$kube_vip_image" \
        vip /kube-vip manifest pod \
        --interface "${interface}" \
        --address "${vip_address}" \
        --controlplane \
        --services \
        --arp \
        --k8sConfigPath "${k8s_config_path}" \
        --leaderElection > /etc/kubernetes/manifests/kube-vip.yaml
}

# Waits for a specific Pod in a namespace to be ready
#
# Args:
#  - namespace: The namespace of the Pod
#  - pod: The name of the Pod
_wait_for_pod_ready() {
    local namespace="$1" pod="$2"
    
    log "Waiting for Pod ${pod} in namespace ${namespace} to be ready..."
    until kubectl get pods -n "${namespace}" | grep "${pod}" | \
    grep Running &>/dev/null; do
        sleep 2
        echo "Waiting..."
    done
}

# Applies the Calico CNI plugin to the cluster using the latest release
_apply_calico() {
    local latest_url="https://api.github.com/repos/projectcalico/calico/releases/latest"

    local version
    version=$(curl -sSL "${latest_url}" | jq -r .tag_name)
    
    local url="https://raw.githubusercontent.com/projectcalico/calico/\
${version}/manifests/calico.yaml"
    
    log "Applying Calico CNI plugin version ${version} from ${url}..."

    kubectl apply -f "${url}"
}

# Initializes a high-availability control-plane node
#
# Args:
#  - vip_address: The control-plane endpoint (VIP or DNS name)
_init_control_plane() {
    local cluster_id="${1}" vip_address="${2}"

    log "Initializing the Kubernetes cluster: ${cluster_id} \
with control-plane endpoint: ${vip_address}..."

    cat <<EOF | tee /tmp/kubeadm-config.yaml >/dev/null
apiVersion: kubeadm.k8s.io/v1beta4
kind: ClusterConfiguration
name: ${cluster_id}
kubernetesVersion: stable
controlPlaneEndpoint: "${vip_address}:6443"
networking:
  podSubnet: "10.244.0.0/16"
apiServer:
  certSANs:
  - "${vip_address}"
  - "127.0.0.1"
EOF

    # Initialize the control-plane with kubeadm
    kubeadm init --config /tmp/kubeadm-config.yaml --upload-certs
}

# Joins a high-availability control-plane node to the cluster using kubeadm
# Requires the following environment variables to be set:
#  - KUBE_PROVISION_ADDRESS: The control-plane endpoint (VIP or DNS name)
#  - KUBE_PROVISION_TOKEN: The kubeadm join token
#  - KUBE_PROVISION_CERT_HASH: The certificate hash
#  - KUBE_PROVISION_CERT_KEY: The certificate key for joining the cluster
_join_control_plane() {
    local cluster_id="$1"
    local hostname
    hostname=$(hostname -f)

    log "Joining control-plane node: ${hostname} to Kubernetes \
cluster: ${cluster_id} at ${KUBE_PROVISION_ADDRESS}..."

    # Join the node as a control-plane node with kubeadm
    kubeadm join \
        "${KUBE_PROVISION_ADDRESS}:6443" \
        --token "${KUBE_PROVISION_TOKEN}" \
        --discovery-token-ca-cert-hash "sha256:${KUBE_PROVISION_CERT_HASH}" \
        --control-plane --certificate-key "${KUBE_PROVISION_CERT_KEY}"
}

# Joins a worker node to the cluster using kubeadm
# Requires the following environment variables to be set:
#  - KUBE_PROVISION_ADDRESS: The control-plane endpoint (VIP or DNS name)
#  - KUBE_PROVISION_TOKEN: The kubeadm join token
#  - KUBE_PROVISION_CERT_HASH: The certificate hash
_join_worker() {
    local cluster_id="$1"
    local hostname
    hostname=$(hostname -f)

    log "Joining worker node: ${hostname} to Kubernetes cluster: \
${cluster_id} at ${KUBE_PROVISION_ADDRESS}..."

    # Join the node as a worker node with kubeadm
    kubeadm join \
        "${KUBE_PROVISION_ADDRESS}" \
        --token "${KUBE_PROVISION_TOKEN}" \
        --discovery-token-ca-cert-hash "sha256:${KUBE_PROVISION_CERT_HASH}"
}

# Sets up the Kubernetes apt repository
#
# Args:
#  - cluster_id: The cluster identifier
#  - method: The method to use (init or join)
#  - vip_address: The virtual IP address to be used by kube-vip
_configure_control_plane() {
    local cluster_id="${1}" method="${2}" vip_address="${3}" parameter_store_bucket="${4}"
    local k8s_config_path
    # If this is the first control-plane node being initialized, we need to use
    # super-admin.conf for kube-vip to create the static Pod manifest
    # see github.com/kube-vip/kube-vip/issues/684
    if [[ "${method}" == "init" ]]; then
        k8s_config_path="/etc/kubernetes/super-admin.conf"
    elif [[ "${method}" == "join" ]]; then
        k8s_config_path="/etc/kubernetes/admin.conf"
    fi

    # Create the kube-vip static Pod manifest
    _create_kube_vip_static_pod_manifiest "${vip_address}" "${k8s_config_path}"

    if [[ "${method}" == "init" ]]; then
        # Initialize the control-plane
        _init_control_plane "${cluster_id}" "${vip_address}"

        # Set up kubeconfig for kubectl
        _setup_kube_config

        # Wait for kube-vip Pod to be ready
        _wait_for_pod_ready "kube-system" "kube-vip"

        # Apply the Calico CNI plugin
        _apply_calico

        # Store the parameters in the parameter store
        store_parameters "${cluster_id}" "${parameter_store_bucket}"
    elif [[ "${method}" == "join" ]]; then
        # Retrieve the parameters from the parameter store and set 
        # them as environment variables
        retrieve_parameters "${cluster_id}" "${parameter_store_bucket}"
        
        # Join the control-plane
        _join_control_plane "${cluster_id}"

        # Set up kubeconfig for kubectl
        _setup_kube_config
    fi

    # Create the parameter store cronjob to back up parameters every 6 hours
    create_parameter_store_cronjob "${cluster_id}" "${parameter_store_bucket}"

    log "Kubernetes control-plane node configured successfully..."
}

# Configures the Kubernetes cluster based on the node role and type
#
# Args:
#  - cluster_id: The cluster identifier
#  - role: The node role (control-plane or worker)
#  - method: The method to use (init or join)
#  - vip_address: The virtual IP address to be used by kube-vip for HA
configure_kubernetes() {
    local cluster_id="${1}" role="${2}" method="${3}" vip_address="${4}"

    if [[ "${role}" == "control-plane" ]]; then
        _configure_control_plane "${cluster_id}" "${method}" "${vip_address}"

        # Remove taint from control-plane node to allow scheduling Pods
        kubectl taint nodes --all node-role.kubernetes.io/control-plane- || true

        # Change the node-role.kubernetes.io/control-plane label to
        # node-role.kubernetes.io/node
        kubectl label node "$(hostname)" node-role.kubernetes.io/control-plane- --overwrite || true

        kubectl label node "$(hostname)" "node-role.kubernetes.io/node=" --overwrite
    elif [[ "${role}" == "worker" ]]; then
        # Retrieve the parameters from the parameter store and set 
        # them as environment variables
        retrieve_parameters "${cluster_id}"

        # Join the worker node to the cluster
        _join_worker "${cluster_id}"
    fi
}