# kube-provisioner

kube-provisioner is a small collection of scripts to provision a highly-available
Kubernetes cluster (kubeadm) on a set of Linux hosts. The repository automates
common setup tasks (container runtime, kernel/networking settings), installs the
Kubernetes packages, and configures a high-availability control plane using
kube-vip for a virtual IP (VIP).

This project is intended for lab, test, and small production environments where
you want reproducible, scripted provisioning of control-plane and worker nodes
with kubeadm.
