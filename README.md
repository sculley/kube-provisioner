# kube-deploy

**Multi‑master Kubernetes bootstrap via kubeadm and kube‑vip**

kube‑deploy is a self‑contained Bash utility for creating and managing high‑availability Kubernetes clusters on bare‑metal or virtual machines. It leverages [kubeadm](https://kubernetes.io/docs/setup/production-environment/tools/kubeadm/install-kubeadm/) for cluster bootstrapping and [kube‑vip](https://kube-vip.io/) to provide a floating virtual IP and load balancing for the control plane. By encapsulating the installation and configuration steps in a single script, kube‑deploy eliminates the need for configuration management tooling such as Ansible or external load balancers.

kube‑vip offers Kubernetes‑native high availability and load balancing on control plane nodes so you don’t need to deploy HAProxy or Keepalived to achieve HA. The project has evolved from a simple control‑plane failover helper into a general LoadBalancer service: it supports IPv4 or IPv6 VIPs, ARP or BGP leader election, static Pod or DaemonSet modes, and can even allocate service LoadBalancer addresses per namespace. Since v0.4.0, kube‑vip can configure IPVS to perform layer‑4 round‑robin load balancing across all control‑plane nodes, further simplifying the architecture.

## Features

- **High‑availability control planes** – Automates the process of initialising a stacked etcd control plane with `kubeadm`, generating a join token and certificate key, and capturing the discovery hash in a secure environment file.
- **kube‑vip integration** – Writes a static Pod manifest for kube‑vip to `/etc/kubernetes/manifests` before the control plane is created. This provides a floating VIP and IPVS load balancing for the API server【159012553714953†L410-L427】.
- **Supports multiple roles** – A single script handles dependency installation (`deps`), initialising the first control plane (`init`), joining additional control planes (`join-control-plane`), joining workers (`join-worker`), and resetting a node (`reset`).
- **Minimal dependencies** – Requires only a Debian/Ubuntu‑like system with `apt`, `curl` and `bash`. Installs containerd, kubeadm, kubelet and kubectl from the official Kubernetes repositories.
- **Configurable** – Accepts flags and environment variables to set the Kubernetes version, pod and service CIDRs, CNI plugin, VIP address and interface, and kube‑vip image. You can enable or disable kube‑vip as needed.
- **Secure secret handling** – Stores the join token, discovery hash and certificate key in a root‑only file (`/opt/kubeadm/cluster-join.env`) that can be securely copied to new nodes.

## Prerequisites

- **Operating system** – Ubuntu 20.04+ or a similar Debian‑based distribution. The script uses `apt` to install packages.
- **Root privileges** – `sudo` or root access is required to disable swap, write system config files and run `kubeadm`.
- **Networking** – A static IP address for each node and a dedicated Virtual IP (VIP) in the same L2 subnet for kube‑vip. Ensure the VIP interface is reachable from all control planes.
- **Internet access** – The script fetches packages from `pkgs.k8s.io` and pulls container images.

## Quick start

1. **Download the script** and make it executable:

   ```bash
   curl -fsSL -o kube-deploy.sh <URL-to-your-script>
   chmod +x kube-deploy.sh
   ```

2. **Install prerequisites** on each node:

   ```bash
   sudo ./kube-deploy.sh --role deps --k8s-version v1.34.0
   ```

3. **Initialise the first control plane** (choose your VIP and interface):

   ```bash
   sudo ./kube-deploy.sh --role init \
     --enable-kube-vip \
     --vip 192.168.122.20 \
     --vip-iface br0 \
     --apiserver-endpoint 192.168.122.20:6443
   ```

   This step will:

   - Disable swap and configure sysctl/kernel modules.
   - Install containerd and Kubernetes packages.
   - Write a kube‑vip static Pod manifest with `lb_enable` and `lb_port` set for IPVS load balancing【159012553714953†L410-L427】.
   - Run `kubeadm init` with `--upload-certs`, generate a token and certificate key, and store them in `/opt/kubeadm/cluster-join.env`.
   - Optionally apply Flannel CNI (set `--cni none` to skip).
   - Remove control‑plane taints so workloads can run on control‑plane nodes when there are no dedicated workers.

4. **Copy the join environment file** `/opt/kubeadm/cluster-join.env` from the first node to each additional node (this file contains sensitive information; handle with care).

5. **Join additional control planes** (with kube‑vip enabled):

   ```bash
   sudo ./kube-deploy.sh --role join-control-plane \
     --enable-kube-vip \
     --vip 192.168.122.20 \
     --vip-iface br0
   ```

6. **Join workers** if needed:

   ```bash
   sudo ./kube-deploy.sh --role join-worker
   ```

7. **Reset a node**:

   ```bash
   sudo ./kube-deploy.sh --role reset
   ```

## Customisation

kube‑deploy exposes several flags and environment variables:

| Flag/variable       | Description                                                                                         |
| ------------------- | --------------------------------------------------------------------------------------------------- |
| `--k8s-version`     | Sets the Kubernetes version for `kubeadm`, `kubelet` and `kubectl`. Default: `v1.30.0`.             |
| `--pod-cidr`        | Pod CIDR used by your CNI (Flannel’s default is `10.244.0.0/16`).                                   |
| `--svc-cidr`        | Service CIDR (default `10.96.0.0/12`).                                                              |
| `--cni`             | CNI plugin to apply automatically (`flannel` or `none`).                                            |
| `--enable-kube-vip` | Enables kube‑vip deployment. Requires `--vip` and `--vip-iface`.                                    |
| `--vip`             | The virtual IP address to advertise for the API server.                                             |
| `--vip-iface`       | The network interface on which to bind the VIP (e.g. `br0`, `ens3`).                                |
| `--kube-vip-image`  | Override the kube‑vip container image tag. Default: `ghcr.io/kube-vip/kube-vip:v0.7.2`.             |
| `--token-ttl`       | TTL for the join token (e.g. `2h`, `24h`). A new token can be generated via `kubeadm token create`. |
| `--join-env`        | Path to the join environment file. Default: `/opt/kubeadm/cluster-join.env`.                        |

You can also set corresponding environment variables (e.g. `K8S_VERSION`, `VIP_ADDRESS`) instead of passing flags.

## Security considerations

- **Protect the join file** – The file `/opt/kubeadm/cluster-join.env` contains the join token, discovery hash and certificate key. Treat it like a secret. Delete it after all nodes have joined.
- **Limit remote access** – Expose port 6443 only to trusted networks. If you need to make the cluster’s API reachable from the internet, forward the host’s public port 6443 to the VIP and secure it with a firewall.
- **Rotate tokens** – By default `kubeadm init` creates a token with a 24‑hour TTL. You can specify a different TTL with `--token-ttl` or generate a new token later.

## Contributing

Contributions and bug reports are welcome! Feel free to open issues or pull requests on the project’s GitHub repository. When contributing, follow conventional commit messages and include clear descriptions of your changes.

## License

This project is licensed under the MIT License. See the [LICENSE](LICENSE) file for details.

---

### References

- [kube-vip](https://kube-vip.io)
