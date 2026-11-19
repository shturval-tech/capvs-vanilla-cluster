#!/bin/bash

# Upstream CAPV workaround for kube-vip with kubeadm >= 1.29:
# during "kubeadm init" the admin.conf kubeconfig does not exist yet.
# Use super-admin.conf while the control plane is initializing.
set -e

KUBEADM_MINOR="$(kubeadm version -o short | cut -d '.' -f 2)"
if [[ "$KUBEADM_MINOR" -lt "29" ]]; then
  exit 0
fi

IS_KUBEADM_INIT="false"

if [[ -f /run/kubeadm/kubeadm.yaml ]]; then
  IS_KUBEADM_INIT="true"
fi

if [[ -f /etc/kubeadm.sh ]] && grep -q -e "kubeadm init" /etc/kubeadm.sh; then
  IS_KUBEADM_INIT="true"
fi

if [[ "$IS_KUBEADM_INIT" == "true" ]]; then
  sed -i 's#path: /etc/kubernetes/admin.conf#path: /etc/kubernetes/super-admin.conf#' \
    /etc/kubernetes/manifests/kube-vip.yaml
fi
