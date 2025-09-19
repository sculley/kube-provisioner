#!/usr/bin/env bash
set -euo pipefail

# shellcheck disable=SC1090,SC1091
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

_disable_swap() {
	log "Disabling swap..."

	sudo swapoff -a
	sudo perl -p -i -e  's,^/swap,#/swap,' /etc/fstab
	sudo swapon --show
	echo "Don't forget to reboot to have swap disabled"
}

_enable_ip_forward() {
	log "Enabling IPv4 forwarding..."

	cat <<EOF | sudo tee /etc/sysctl.d/kubeadm.conf
net.ipv4.ip_forward = 1
EOF
	sudo sysctl --system |grep ip_forward
}

_setup_kube_repo() {
    log "Setting up Kubernetes apt repository..."

    # This variable is set from the functions first argument
    local version="$1"

    # Ensure the keyrings directory exists
    sudo install -d -m 0755 /etc/apt/keyrings

	# Download and add the GPG key for the Kubernetes apt repository
	local key_url="https://pkgs.k8s.io/core:/stable:/\
v${version%.*}/deb/Release.key"
	curl -fsSL "$key_url" \
		| sudo gpg --batch --yes --dearmor \
		-o /etc/apt/keyrings/kubernetes-apt-keyring.gpg

	# Add the Kubernetes apt repository
	local kubernetes_repo="deb [signed-by=/etc/apt/keyrings/\
		kubernetes-apt-keyring.gpg]"
	kubernetes_repo+=" https://pkgs.k8s.io/core:/stable:/\
v${version%.*}/deb/ /"
	echo "$kubernetes_repo" | sudo tee /etc/apt/sources.list.d/kubernetes.list \
		>/dev/null

    # Update package lists
    sudo apt-get update -y
}

_install_kubectl() {
	local version="$1"

	log "Installing kubectl-${version}"

	sudo apt-get update
	sudo apt-get install -y kubectl="${version}"-*
	sudo apt-mark hold kubectl

	log "kubectl installed successfully..."
}

_install_kubelet() {
	local version="$1"

	log "Installing kubelet-${version}"

	sudo apt-get update
	sudo apt-get install -y kubelet="${version}"-*
	sudo apt-mark hold kubelet

	log "kubelet installed successfully..."
}

_install_kubeadm() {
	local version="$1"

	# Ensure swap is disabled
	_disable_swap
	# Ensure IP forwarding is enabled
	_enable_ip_forward

	log "Installing kubeadm-$version"

	sudo apt-get update -y
	sudo apt-get install -y kubeadm="${version}"-*
	sudo apt-mark hold kubeadm
}

install_kubernetes() {
	local version="$1"
	[[ -n "$version" ]] || fatal "requires a kubernetes version (e.g. 1.34.0)"

	# Set up the Kubernetes apt repository
	_setup_kube_repo "$version"

	# Install kubectl, kubelet and kubeadm
	_install_kubectl "$version"
	_install_kubelet "$version"
	_install_kubeadm "$version"

	log "kubectl, kubelet and kubeadm installed successfully..."
}