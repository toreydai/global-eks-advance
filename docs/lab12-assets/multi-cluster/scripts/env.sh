#!/usr/bin/env bash
set -euo pipefail

export AWS_REGION="${AWS_REGION:-us-east-1}"
export CLUSTER1="${CLUSTER1:-istio-primary}"
export CLUSTER2="${CLUSTER2:-istio-remote}"
export CTX_CLUSTER1="${CTX_CLUSTER1:-istio-primary}"
export CTX_CLUSTER2="${CTX_CLUSTER2:-istio-remote}"
export EKS_VERSION="${EKS_VERSION:-1.36}"
export ISTIO_VERSION="${ISTIO_VERSION:-1.30.3}"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export ROOT_DIR
export TOOLS_DIR="${ROOT_DIR}/.tools"
export PATH="${TOOLS_DIR}/bin:${TOOLS_DIR}/istio-${ISTIO_VERSION}/bin:${PATH}"
