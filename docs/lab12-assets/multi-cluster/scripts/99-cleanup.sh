#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/env.sh"

eksctl delete cluster --region "${AWS_REGION}" --name "${CLUSTER2}" --wait
eksctl delete cluster --region "${AWS_REGION}" --name "${CLUSTER1}" --wait
