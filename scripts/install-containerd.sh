#!/bin/bash
set -e

# shellcheck disable=SC1090,SC1091
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

OS=$(uname -s)
ARCH=$(uname -m)
[[ "$ARCH" == x86_64 ]] && ARCH=amd64

_install_containerd() {
    latest_url="https://api.github.com/repos/containerd/containerd/releases/\
latest"
    version=$(curl -sSL "$latest_url" | jq -r .tag_name)
    tmpdir=$(mktemp -d)
    tar_url_base="https://github.com/containerd/containerd/releases/download"
    tar_file="containerd-${version#v}-${OS,,}-${ARCH}.tar.gz"
    tar_url="$tar_url_base/$version/$tar_file"
    curl -sSL "$tar_url" -o "$tmpdir/some.tar.gz"
    sudo tar Cxzvf /usr/local "$tmpdir/some.tar.gz"
        rm -rf "$tmpdir"
}

_install_containerd_service() {
        log "Setting up containerd systemd service..."
        curl -sSL "https://raw.githubusercontent.com/containerd/containerd/\
main/containerd.service" -o /usr/lib/systemd/system/containerd.service
        systemctl daemon-reload
        systemctl enable --now containerd
        systemctl status containerd --no-pager
}

_install_containerd_set_systemdcgroup() {
  # Install dependencies
  sudo apt-get update -y
  sudo apt-get install -y python3-pip python3-toml
  # Generate default config if it does not exist
  sudo mkdir -p /etc/containerd
  # Generate the full config for the installed version
  sudo bash -c "containerd config default > /etc/containerd/config.toml"

  python3 <<'PY'
import toml, os

CFG = "/etc/containerd/config.toml"

with open(CFG, "r") as f:
    conf = toml.load(f)

def ensure_tbl(d, key):
    if key not in d or not isinstance(d[key], dict):
        d[key] = {}
    return d[key]

plugins = ensure_tbl(conf, "plugins")

# Prefer containerd 2.x path, fall back to 1.x if needed
cri_key_v2 = "io.containerd.cri.v1.runtime"
cri_key_v1 = "io.containerd.grpc.v1.cri"

if cri_key_v2 in plugins:
    cri = ensure_tbl(plugins, cri_key_v2)   # containerd 2.x
else:
    cri = ensure_tbl(plugins, cri_key_v1)   # containerd 1.x

containerd_tbl = ensure_tbl(cri, "containerd")
runtimes = ensure_tbl(containerd_tbl, "runtimes")
runc = ensure_tbl(runtimes, "runc")

# Make sure runc uses the v2 shim (good default if missing)
if "runtime_type" not in runc:
    runc["runtime_type"] = "io.containerd.runc.v2"

opts = ensure_tbl(runc, "options")
opts["SystemdCgroup"] = True

with open("/tmp/containerd-config.toml", "w") as f:
    toml.dump(conf, f)
PY

  sudo mv /tmp/containerd-config.toml /etc/containerd/config.toml
  sudo systemctl restart containerd
}

_install_containerd_cni_plugins() {
    log "Installing containerd CNI plugins..."

    latest="https://api.github.com/repos/containernetworking/plugins/\
releases/latest"
    version=$(curl -sSL "$latest" | jq -r .tag_name)
    release_base="https://github.com/containernetworking/plugins/\
releases/download"
    release="${release_base}/$version/cni-plugins-${OS,,}-${ARCH}-\
${version}.tgz"
    tmpdir=$(mktemp -d)
    curl -sSL "$release" -o "$tmpdir/cni-plugins.tgz"
    mkdir -p /opt/cni/bin
    sudo tar Cxzvf /opt/cni/bin "$tmpdir/cni-plugins.tgz"
    rm -rf "$tmpdir"
    sudo chown root:root /opt/cni/bin
}

_install_containerd_bash_completion() {
    log "Installing containerd bash completion..."

    local ctr_completion_url="https://raw.githubusercontent.com/\
containerd/containerd/refs/heads/main/contrib/autocomplete/ctr"
    sudo curl -sSL "$ctr_completion_url" -o /etc/bash_completion.d/ctr
}

_install_runc() {
    log "Installing runc..."

    latest_url="https://api.github.com/repos/opencontainers/runc/\
releases/latest"
    version=$(curl -sSL "$latest_url" | jq -r .tag_name)
    runc_url="https://github.com/opencontainers/runc/releases/\
download/$version/runc.amd64"
    sudo curl -sSL "$runc_url" -o /usr/local/bin/runc
    sudo chmod +x /usr/local/bin/runc
    runc --version
}

_install_runc_bash_completion() {
    log "Installing runc bash completion..."

    sudo curl -sSL https://raw.githubusercontent.com/opencontainers/\
runc/master/contrib/completions/bash/runc -o /etc/bash_completion.d/runc
}

install_containerd() {
    log "Installing containerd..."

    _install_containerd
    _install_containerd_service
    _install_containerd_cni_plugins
    _install_containerd_set_systemdcgroup
    _install_containerd_bash_completion
    _install_runc
    _install_runc_bash_completion
    
    log "containerd installed successfully..."
}