#!/usr/bin/env bash
#
# kube-deploy.sh
#
# A self contained helper script for bootstrapping a high availability
# Kubernetes cluster with kubeadm.  It installs the required OS
# packages, disables swap, sets kernel parameters, deploys containerd
# and Kubernetes tools, and optionally writes a static Pod manifest
# for kube‑vip.  The same script can be run on the first control
# plane, additional control planes and worker nodes.  A small
# environment file is used to share the join token, discovery hash
# and certificate key between nodes.
#
# Usage examples:
#   # Prepare any node (install packages, disable swap, etc.)
#   sudo ./kube-deploy.sh --role deps --k8s-version v1.34.0
#
#   # Initialise the first control plane with kube‑vip on 192.168.122.20:6443
#   sudo ./kube-deploy.sh --role init \
#       --enable-kube-vip --vip 192.168.122.20 --vip-iface br0 \
#       --apiserver-endpoint 192.168.122.20:6443
#
#   # On additional control planes copy /opt/kubeadm/cluster-join.env
#   # from the first node, then run:
#   sudo ./kube-deploy.sh --role join-control-plane \
#       --enable-kube-vip --vip 192.168.122.20 --vip-iface br0
#
#   # Join workers (if any) using the same environment file:
#   sudo ./kube-deploy.sh --role join-worker
#
#   # Reset a node if necessary:
#   sudo ./kube-deploy.sh --role reset

set -euo pipefail

# Default configuration.  Users may override these via environment
# variables or CLI flags.  Some variables are left empty and must be
# provided when required (e.g. API_ENDPOINT for init, VIP_ADDRESS
# when kube‑vip is enabled).
K8S_VERSION="${K8S_VERSION:-v1.30.0}"
POD_CIDR="${POD_CIDR:-10.244.0.0/16}"
SVC_CIDR="${SVC_CIDR:-10.96.0.0/12}"
API_ENDPOINT="${API_ENDPOINT:-}"
JOIN_ENV_PATH="${JOIN_ENV_PATH:-/opt/kubeadm/cluster-join.env}"
CNI="${CNI:-flannel}"
TOKEN_TTL="${TOKEN_TTL:-24h}"

# kube‑vip related flags.  Set ENABLE_KUBE_VIP=true to deploy
# kube‑vip as a static Pod on control plane nodes.  VIP_ADDRESS and
# VIP_INTERFACE must be specified when kube‑vip is enabled.  You can
# override KUBE_VIP_IMAGE to use a different image tag.
ENABLE_KUBE_VIP="${ENABLE_KUBE_VIP:-false}"
VIP_ADDRESS="${VIP_ADDRESS:-}"
VIP_INTERFACE="${VIP_INTERFACE:-}"
KUBE_VIP_IMAGE="${KUBE_VIP_IMAGE:-ghcr.io/kube-vip/kube-vip:v0.7.2}"

# Logging helpers.  Use colours to make output easier to read.  All
# logging goes to stdout except for err() which goes to stderr.
log()  { printf '\033[1;32m[INFO]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[WARN]\033[0m %s\n' "$*"; }
err()  { printf '\033[1;31m[ERR ]\033[0m %s\n' "$*" >&2; }
die()  { err "$*"; exit 1; }

# Ensure we are running as root.  kubeadm and many OS tweaks
# require root privileges.  This helper will exit with an error
# message if the script is not executed as root.
need_root() {
  if [[ ${EUID} -ne 0 ]]; then
    die "This script must be run as root. Use sudo to run it."
  fi
}

# Disable swap permanently.  kubeadm will refuse to run if swap is
# enabled.  The function comments out any active swap entries in
# /etc/fstab and turns off swap immediately.
disable_swap() {
  # Comment out swap entries in /etc/fstab
  if grep -qE '\s+swap\s' /etc/fstab; then
    sed -ri 's/(\s)swap(\s)/\1swap_disabled\2/g' /etc/fstab
  fi
  # Turn off swap now
  swapoff -a || true
}

# Configure kernel modules and sysctl parameters required by
# Kubernetes networking.  We load overlay and br_netfilter modules
# persistently via /etc/modules-load.d and set bridge and IP forward
# settings via a dedicated sysctl file.  After writing the files we
# run sysctl --system to apply settings immediately.
sysctl_k8s() {
  cat >/etc/modules-load.d/k8s.conf <<'EOF'
overlay
br_netfilter
EOF
  modprobe overlay || true
  modprobe br_netfilter || true
  cat >/etc/sysctl.d/99-kubernetes-cri.conf <<'EOF'
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF
  sysctl --system > /dev/null
}

# Install containerd from the OS repositories.  We ensure apt
# metadata is current, install necessary packages and generate a
# default configuration.  We then switch containerd to use the
# systemd cgroup driver which is recommended for kubeadm.
install_containerd() {
  apt-get update -y
  apt-get install -y apt-transport-https ca-certificates curl gnupg lsb-release
  # Install containerd from default repositories.  For Ubuntu this
  # typically installs a recent version which is suitable for
  # Kubernetes.  If you require a specific version you can modify
  # this installation.
  apt-get install -y containerd
  mkdir -p /etc/containerd
  if [[ ! -f /etc/containerd/config.toml ]]; then
    containerd config default >/etc/containerd/config.toml
  fi
  # Switch to systemd cgroup driver
  sed -ri 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
  systemctl enable --now containerd
}

# Install kubeadm, kubelet and kubectl from the official Kubernetes
# repositories.  We add the apt repository for the specified
# Kubernetes version series (e.g. v1.34) and install the packages.
# After installation we mark them on hold so they are not
# automatically upgraded.
install_kube_tools() {
  install -m 0755 -d /etc/apt/keyrings
  local release_key_url="https://pkgs.k8s.io/core:/stable:/v${K8S_VERSION#v}/deb/Release.key"
  curl -fsSL "$release_key_url" | gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
  echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v${K8S_VERSION#v}/deb/ /" \
    >/etc/apt/sources.list.d/kubernetes.list
  apt-get update -y
  apt-get install -y kubelet kubeadm kubectl
  apt-mark hold kubelet kubeadm kubectl
  systemctl enable kubelet
}

# Top level function to prepare a node with all required
# dependencies.  This should be run on every node before joining
# the cluster.  It calls the helpers above in sequence.
deps() {
  need_root
  log "Disabling swap"
  disable_swap
  log "Configuring sysctl and kernel modules"
  sysctl_k8s
  log "Installing containerd"
  install_containerd
  log "Installing Kubernetes tools (${K8S_VERSION})"
  install_kube_tools
}

# Write a join environment file containing the API endpoint,
# join token, discovery token CA cert hash and the certificate key.
# The file is created with restrictive permissions.  Users must
# securely copy this file to additional nodes.  The file is used
# by read_join_env() to reconstruct the kubeadm join command.
write_join_env() {
  local api="$1" token="$2" hash="$3" certkey="$4"
  install -d -m 0750 "$(dirname "$JOIN_ENV_PATH")"
  umask 077
  cat >"$JOIN_ENV_PATH" <<EOF
# kubeadm join parameters (sensitive)
API_ENDPOINT="$api"
KUBEADM_TOKEN="$token"
DISCOVERY_HASH="$hash"
CERT_KEY="$certkey"
EOF
  chmod 0600 "$JOIN_ENV_PATH"
  log "Join secrets written to $JOIN_ENV_PATH"
}

# Read the join environment file written by write_join_env().
# It sources the file to populate variables in the current shell.
read_join_env() {
  if [[ ! -f "$JOIN_ENV_PATH" ]]; then
    die "Join environment file not found: $JOIN_ENV_PATH"
  fi
  # shellcheck source=/dev/null
  source "$JOIN_ENV_PATH"
  if [[ -z "${API_ENDPOINT:-}" || -z "${KUBEADM_TOKEN:-}" || -z "${DISCOVERY_HASH:-}" ]]; then
    die "Join environment file is missing required fields"
  fi
}

# Write a static Pod manifest for kube‑vip into
# /etc/kubernetes/manifests.  When kubelet sees this manifest it
# automatically runs kube‑vip as a Pod in the kube‑system namespace.
# kube‑vip will manage the virtual IP and load balance traffic
# between control plane nodes.  This function is executed before
# kubeadm init and before joining control planes.  It uses the
# configured VIP_ADDRESS, VIP_INTERFACE and KUBE_VIP_IMAGE.  The
# environment variables cp_enable and lb_enable enable control plane
# HA and API load balancing via IPVS.
install_kube_vip_static_pod() {
  if [[ "${ENABLE_KUBE_VIP}" != "true" ]]; then
    return 0
  fi
  if [[ -z "${VIP_ADDRESS}" || -z "${VIP_INTERFACE}" ]]; then
    die "--vip and --vip-iface must be specified when kube‑vip is enabled"
  fi
  install -d -m 0755 /etc/kubernetes/manifests
  cat >/etc/kubernetes/manifests/kube-vip.yaml <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: kube-vip
  namespace: kube-system
  labels:
    app.kubernetes.io/name: kube-vip
spec:
  hostNetwork: true
  priorityClassName: system-cluster-critical
  tolerations:
    - key: node-role.kubernetes.io/control-plane
      operator: Exists
      effect: NoSchedule
    - key: node-role.kubernetes.io/master
      operator: Exists
      effect: NoSchedule
  containers:
    - name: kube-vip
      image: ${KUBE_VIP_IMAGE}
      imagePullPolicy: IfNotPresent
      args:
        - "manager"
      securityContext:
        capabilities:
          add:
            - NET_ADMIN
            - NET_RAW
            - SYS_TIME
      env:
        - name: vip_address
          value: "${VIP_ADDRESS}"
        - name: vip_interface
          value: "${VIP_INTERFACE}"
        - name: vip_arp
          value: "true"
        - name: cp_enable
          value: "true"
        - name: lb_enable
          value: "true"
        - name: lb_port
          value: "6443"
        - name: prometheus_server
          value: "false"
  restartPolicy: Always
EOF
  log "kube‑vip static Pod manifest written to /etc/kubernetes/manifests/kube-vip.yaml"
}

# Initialise the first control plane.  This function performs the
# following actions:
#   * Installs kube‑vip static manifest if enabled.
#   * Runs kubeadm init with the provided API_ENDPOINT and
#     networking configuration.  --upload-certs is used to upload
#     control plane certificates for use by join-control-plane.
#   * Generates a new token with a TTL and computes the discovery
#     token CA cert hash.  It then runs upload-certs again to
#     regenerate the certificate key, and writes all join details
#     into the join environment file.
#   * Copies admin.conf to /root/.kube for convenience.
#   * Applies the flannel CNI if selected.
#   * Removes control plane taints so pods can schedule on control
#     planes when there are no workers.
kubeadm_init_first_cp() {
  need_root
  install_kube_vip_static_pod
  if [[ -z "${API_ENDPOINT}" ]]; then
    die "--apiserver-endpoint is required for init"
  fi
  log "Running kubeadm init for control plane endpoint ${API_ENDPOINT}"
  kubeadm init \
    --kubernetes-version "${K8S_VERSION}" \
    --control-plane-endpoint "${API_ENDPOINT}" \
    --pod-network-cidr "${POD_CIDR}" \
    --service-cidr "${SVC_CIDR}" \
    --upload-certs

  # Prepare kubectl config for root user
  mkdir -p /root/.kube
  cp -f /etc/kubernetes/admin.conf /root/.kube/config
  chown root:root /root/.kube/config

  # Create a new kubeadm token with TTL
  local token
  token="$(kubeadm token create --ttl "${TOKEN_TTL}")"

  # Calculate the discovery token CA cert hash.  We extract the
  # public key from the CA certificate and compute a SHA256 hash.
  local hash
  hash="$(openssl x509 -pubkey -in /etc/kubernetes/pki/ca.crt | \
      openssl rsa -pubin -outform der 2>/dev/null | \
      openssl dgst -sha256 -hex | awk '{print $2}')"

  # Upload certs again to print the certificate key (last line)
  local certkey
  certkey="$(kubeadm init phase upload-certs --upload-certs | tail -1)"

  # Persist join information
  write_join_env "${API_ENDPOINT}" "${token}" "${hash}" "${certkey}"

  # Apply CNI plugin if requested
  if [[ "${CNI}" == "flannel" ]]; then
    log "Applying Flannel CNI"
    kubectl --kubeconfig /etc/kubernetes/admin.conf apply -f \
      https://raw.githubusercontent.com/flannel-io/flannel/master/Documentation/kube-flannel.yml
  else
    warn "CNI '${CNI}' selected; skipping automatic network addon install"
  fi

  # Remove control plane taints to allow scheduling workloads when
  # there are no dedicated worker nodes
  kubectl --kubeconfig /etc/kubernetes/admin.conf taint nodes --all node-role.kubernetes.io/control-plane- || true
  kubectl --kubeconfig /etc/kubernetes/admin.conf taint nodes --all node-role.kubernetes.io/master- || true

  log "Control plane initialised successfully.  Distribute ${JOIN_ENV_PATH} to other nodes."
}

# Join an additional control plane node.  We install kube‑vip static
# manifest if enabled, read the join environment file and join
# kubeadm with --control-plane and the certificate key.  The
# discovery token CA cert hash is prefixed with sha256: as required
# by kubeadm.
kubeadm_join_cp() {
  need_root
  install_kube_vip_static_pod
  read_join_env
  log "Joining this node as an additional control plane at ${API_ENDPOINT}"
  kubeadm join "${API_ENDPOINT}" \
    --token "${KUBEADM_TOKEN}" \
    --discovery-token-ca-cert-hash "sha256:${DISCOVERY_HASH}" \
    --control-plane \
    --certificate-key "${CERT_KEY}"
}

# Join a worker node.  We read the join environment file and call
# kubeadm join without the control-plane flag.  This function does
# not install kube‑vip because worker nodes do not host the API
# server.
kubeadm_join_worker() {
  need_root
  read_join_env
  log "Joining this node as a worker at ${API_ENDPOINT}"
  kubeadm join "${API_ENDPOINT}" \
    --token "${KUBEADM_TOKEN}" \
    --discovery-token-ca-cert-hash "sha256:${DISCOVERY_HASH}"
}

# Reset a node back to its pre-cluster state.  We call kubeadm
# reset -f, restart containerd and flush nat rules.  This is
# primarily useful for reusing VMs or cleaning up failures.
reset_node() {
  need_root
  kubeadm reset -f || true
  systemctl restart containerd || true
  iptables -t nat -F || true
  warn "Node has been reset.  Remove ${JOIN_ENV_PATH} if no longer needed."
}

# Print usage information.  This function is invoked when no
# recognised role is given or when --help is passed on the command
# line.
usage() {
  cat <<EOF
Usage: sudo $0 --role <deps|init|join-control-plane|join-worker|reset> [options]

Roles:
  deps                 Install dependencies (swap off, sysctl, containerd, kube tools)
  init                 Initialise the first control plane
  join-control-plane   Join additional control plane nodes
  join-worker          Join worker nodes
  reset                Reset this node (cleanup)

Common options:
  --k8s-version <ver>         Kubernetes version (default: ${K8S_VERSION})
  --pod-cidr <cidr>           Pod CIDR (default: ${POD_CIDR})
  --svc-cidr <cidr>           Service CIDR (default: ${SVC_CIDR})
  --cni <name>                CNI (flannel|none) (default: ${CNI})
  --join-env <file>           Path to join env file (default: ${JOIN_ENV_PATH})

Init role options:
  --apiserver-endpoint <ip:port>   VIP or IP of control plane endpoint (required)
  --token-ttl <duration>           kubeadm token TTL (default: ${TOKEN_TTL})

kube‑vip options:
  --enable-kube-vip           Enable kube‑vip for HA and load balancing
  --vip <vip>                 Virtual IP address (required when enabling kube‑vip)
  --vip-iface <iface>         Interface on which to bind VIP (required when enabling kube‑vip)
  --kube-vip-image <image>    Override kube‑vip container image (default: ${KUBE_VIP_IMAGE})

Examples:
  # Prepare node
  sudo $0 --role deps --k8s-version v1.34.0

  # First control plane with kube‑vip
  sudo $0 --role init --enable-kube-vip \
    --vip 192.168.122.20 --vip-iface br0 \
    --apiserver-endpoint 192.168.122.20:6443

  # Additional control plane
  sudo $0 --role join-control-plane --enable-kube-vip \
    --vip 192.168.122.20 --vip-iface br0

  # Worker node
  sudo $0 --role join-worker

  # Reset node
  sudo $0 --role reset
EOF
}

# Parse command line arguments.  We iterate over all positional
# arguments and shift them as they are consumed.  Unknown options
# cause usage to be displayed.
ROLE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --role) ROLE="$2"; shift 2 ;;
    --k8s-version) K8S_VERSION="$2"; shift 2 ;;
    --pod-cidr) POD_CIDR="$2"; shift 2 ;;
    --svc-cidr) SVC_CIDR="$2"; shift 2 ;;
    --cni) CNI="$2"; shift 2 ;;
    --apiserver-endpoint) API_ENDPOINT="$2"; shift 2 ;;
    --join-env) JOIN_ENV_PATH="$2"; shift 2 ;;
    --token-ttl) TOKEN_TTL="$2"; shift 2 ;;
    --enable-kube-vip) ENABLE_KUBE_VIP="true"; shift 1 ;;
    --vip) VIP_ADDRESS="$2"; shift 2 ;;
    --vip-iface) VIP_INTERFACE="$2"; shift 2 ;;
    --kube-vip-image) KUBE_VIP_IMAGE="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) err "Unknown argument: $1"; usage; exit 1 ;;
  esac
done

# Dispatch based on role.  If no role or an unknown role is
# specified, show usage.
case "${ROLE:-}" in
  deps)
    deps
    ;;
  init)
    deps
    kubeadm_init_first_cp
    ;;
  join-control-plane)
    deps
    kubeadm_join_cp
    ;;
  join-worker)
    deps
    kubeadm_join_worker
    ;;
  reset)
    reset_node
    ;;
  *)
    usage
    exit 1
    ;;
esac