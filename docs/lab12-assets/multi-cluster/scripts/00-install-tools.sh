#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/env.sh"

mkdir -p "${TOOLS_DIR}/bin"

ARCH=amd64
OS="$(uname -s)"

if ! "${TOOLS_DIR}/bin/eksctl" version >/dev/null 2>&1 || [[ "$("${TOOLS_DIR}/bin/eksctl" version)" != "0.229.0" ]]; then
  curl -fsSL "https://github.com/eksctl-io/eksctl/releases/download/v0.229.0/eksctl_${OS}_${ARCH}.tar.gz" \
    -o "${TOOLS_DIR}/eksctl.tar.gz"
  tar -xzf "${TOOLS_DIR}/eksctl.tar.gz" -C "${TOOLS_DIR}/bin" eksctl
fi

if [[ ! -x "${TOOLS_DIR}/istio-${ISTIO_VERSION}/bin/istioctl" ]]; then
  curl -fsSL "https://github.com/istio/istio/releases/download/${ISTIO_VERSION}/istio-${ISTIO_VERSION}-linux-amd64.tar.gz" \
    -o "${TOOLS_DIR}/istio-${ISTIO_VERSION}.tar.gz"
  tar -xzf "${TOOLS_DIR}/istio-${ISTIO_VERSION}.tar.gz" -C "${TOOLS_DIR}"
fi

eksctl version
kubectl version --client
istioctl version --remote=false
