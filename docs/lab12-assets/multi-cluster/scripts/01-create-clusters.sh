#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/env.sh"

eksctl create cluster -f "${ROOT_DIR}/configs/eks-primary.yaml"
eksctl create cluster -f "${ROOT_DIR}/configs/eks-remote.yaml"

aws eks update-kubeconfig --region "${AWS_REGION}" --name "${CLUSTER1}" --alias "${CTX_CLUSTER1}"
aws eks update-kubeconfig --region "${AWS_REGION}" --name "${CLUSTER2}" --alias "${CTX_CLUSTER2}"

kubectl --context="${CTX_CLUSTER1}" get nodes
kubectl --context="${CTX_CLUSTER2}" get nodes
