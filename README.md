# kube-provisioner

kube-provisioner is a small collection of scripts to provision a highly-available
Kubernetes cluster (kubeadm) on a set of Linux hosts. The repository automates
common setup tasks (container runtime, kernel/networking settings), installs the
Kubernetes packages, and configures a high-availability control plane using
kube-vip for a virtual IP (VIP). It also installs common add-ons such as
Calico, cert-manager, and external-dns via Helm.

This project is intended for lab, test, and small production environments where
you want reproducible, scripted provisioning of control-plane and worker nodes
with kubeadm.

## What it installs and configures

- containerd (container runtime)
- sets kernel / sysctl settings required by Kubernetes (IP forwarding, swap off)
- Kubernetes packages: kubeadm, kubelet, kubectl (specific version)
- kube-vip as a static pod manifest to provide a HA control-plane endpoint (VIP)
- Calico CNI (networking) by default
- Helm and a small set of add-ons (external-dns, cert-manager, etc.) via Helm
- Optional: backup/restore of kubeadm join parameters to an S3 bucket

## Repo layout

- `kube-provisioner.sh` - top-level driver script; parses CLI arguments and
  orchestrates the workflow.
- `scripts/` - helper scripts that perform the real work
  - `install-containerd.sh`
  - `install-kubernetes.sh`
  - `configure-kubernetes.sh`
  - `parameter-store.sh` (S3-backed parameter storage)
  - `common.sh` (logging and helper utilities)

## Prerequisites

- A Debian/Ubuntu-compatible host (scripts assume apt tooling and systemd).
- Root privileges (run via `sudo` or as root) because the scripts write to
  `/etc`, install packages, and create system files.
- Network access to the Internet (to download packages and GitHub releases).
- The following tools should be available on the host (the scripts check some):
  - curl
  - jq
  - gpg / gpg --dearmor
  - unzip
  - containerd / ctr (the script can install containerd for you)
  - kubeadm, kubectl, kubelet (installed by the scripts when requested)

If you plan to use the S3-backed parameter store for join tokens, the machine
must have AWS credentials (environment variables or instance profile) with
permissions to read/write the configured S3 path.

## Configuration and environment variables

- AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY, AWS_REGION
  - Required when storing/retrieving kubeadm join parameters in S3.
- `cloudflare_api_token` CLI option (or environment variable handled by caller)
  - Required if you want to install external-dns/cert-manager add-ons that
    interact with Cloudflare.

The S3 bucket/path used by `parameter-store.sh` is currently hard-coded. If you
intend to use the parameter store, update `scripts/parameter-store.sh` or set
up a bucket matching the path used there.

## Usage examples

Basic usage pattern (run from the repository root):

1. Initialize the first control-plane node (init)

```bash
sudo ./kube-provisioner.sh \
  --cluster-name mycluster \
  --role control-plane \
  --method init \
  --k8s-version 1.34.0 \
  --vip-address 10.0.0.100 \
  --cloudflare-api-token YOUR_CLOUDFLARE_API_TOKEN
```

This will:

- install containerd
- install kubeadm/kubelet/kubectl matching `1.34.0`
- create a kube-vip static pod manifest for the given VIP
- run `kubeadm init` with `--control-plane-endpoint` set to the VIP
- configure `kubectl` (copies `/etc/kubernetes/admin.conf` to `/root/.kube`)
- apply Calico and a set of add-ons via Helm

2. Join an additional control-plane node (join)

```bash
sudo ./kube-provisioner.sh \
  --cluster-name mycluster \
  --role control-plane \
  --method join \
  --k8s-version 1.34.0 \
  --vip-address 10.0.0.100
```

3. Join a worker node

```bash
sudo ./kube-provisioner.sh \
  --cluster-name mycluster \
  --role worker \
  --method join \
  --k8s-version 1.34.0
```

4. Install add-ons only (useful after cluster creation)

```bash
sudo ./kube-provisioner.sh --cluster-name mycluster --add-ons-only \
  --cloudflare-api-token YOUR_CLOUDFLARE_API_TOKEN
```

Notes:

- The script will fail if required environment variables (e.g. AWS\_\* for
  parameter store) are missing. See the `kube-provisioner.sh` usage output for
  exact requirements.
- The `--k8s-version` must be in `X.Y.Z` format (e.g. `1.34.0`).

## Troubleshooting and tips

- Permission errors writing to `/etc` or creating cron/logrotate entries:
  - Run the driver script as `sudo` or root. Some helper functions call `sudo`
    while others perform direct redirection; running as root avoids failures.
- Missing tools (jq, curl, unzip, gpg):
  - Install them with `sudo apt-get update && sudo apt-get install -y jq curl unzip gnupg`
- GitHub API rate limits when fetching latest releases (kube-vip/calico):
  - You can avoid API calls by pinning versions in the scripts or caching the
    version/tag you want to use.
- `ctr`/containerd issues:
  - The kube-vip manifest generation uses `ctr` (containerd). Make sure
    containerd is present and running, or adapt the manifest generation to
    use a different method.
- Pod readiness checks can be fragile in some environments. If an add-on
  does not become `Running`, inspect the pod logs with `kubectl -n <ns> logs <pod>`.

## Development notes and recommended next steps

- Consider centralizing the Kubernetes apt repository setup into a single
  function to avoid duplication.
- Make the S3 bucket path configurable via environment variables or CLI flags.
- Improve robustness for production use:
  - Replace ad-hoc `kubectl get pods | grep` checks with `kubectl wait`.
  - Improve parsing of `kubeadm` output (token and cert hash) or extract the
    CA hash directly from `/etc/kubernetes/pki/ca.crt`.

## Contributing

PRs welcome. Please open issues for design questions first. Keep changes small
and focused (e.g., one patch to improve parameter-store behavior, another to
centralize repo setup).

## License

This repository contains utility scripts; add a LICENSE file if you want a
formal license. For now assume `All rights reserved` unless you add a license.
