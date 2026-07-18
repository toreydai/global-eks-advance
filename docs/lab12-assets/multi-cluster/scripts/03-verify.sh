#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/env.sh"

SAMPLES_DIR="${TOOLS_DIR}/istio-${ISTIO_VERSION}/samples"

for ctx in "${CTX_CLUSTER1}" "${CTX_CLUSTER2}"; do
  kubectl --context="${ctx}" create namespace sample --dry-run=client -o yaml | kubectl --context="${ctx}" apply -f -
done
kubectl --context="${CTX_CLUSTER1}" label namespace sample istio-injection=enabled --overwrite
kubectl --context="${CTX_CLUSTER2}" label namespace sample istio-injection- --overwrite || true

kubectl --context="${CTX_CLUSTER2}" -n sample create configmap istio-ca-root-cert \
  --from-file=root-cert.pem="${ROOT_DIR}/.work/certs/cluster2/root-cert.pem" \
  --dry-run=client -o yaml | kubectl --context="${CTX_CLUSTER2}" apply -f -

kubectl --context="${CTX_CLUSTER1}" apply -f "${SAMPLES_DIR}/helloworld/helloworld.yaml" -l service=helloworld -n sample
kubectl --context="${CTX_CLUSTER1}" apply -f "${SAMPLES_DIR}/helloworld/helloworld.yaml" -l version=v1 -n sample
kubectl --context="${CTX_CLUSTER1}" apply -f "${SAMPLES_DIR}/sleep/sleep.yaml" -n sample

DISCOVERY_ADDRESS="$(kubectl --context="${CTX_CLUSTER1}" -n istio-system get svc istio-eastwestgateway -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')"
inject_remote() {
  istioctl kube-inject \
    --injectConfigFile <(kubectl --context="${CTX_CLUSTER1}" -n istio-system get cm istio-sidecar-injector -o jsonpath='{.data.config}') \
    --meshConfigFile <(kubectl --context="${CTX_CLUSTER1}" -n istio-system get cm istio -o jsonpath='{.data.mesh}') \
    --valuesFile <(kubectl --context="${CTX_CLUSTER1}" -n istio-system get cm istio-sidecar-injector -o jsonpath='{.data.values}' | jq --arg d "${DISCOVERY_ADDRESS}" '.global.multiCluster.clusterName="cluster2" | .global.network="network2" | .global.remotePilotAddress=$d') \
    -f "$1"
}

inject_remote "${SAMPLES_DIR}/helloworld/helloworld.yaml" | kubectl --context="${CTX_CLUSTER2}" apply -l service=helloworld -n sample -f -
inject_remote "${SAMPLES_DIR}/helloworld/helloworld.yaml" | kubectl --context="${CTX_CLUSTER2}" apply -l version=v2 -n sample -f -
inject_remote "${SAMPLES_DIR}/sleep/sleep.yaml" | kubectl --context="${CTX_CLUSTER2}" apply -n sample -f -

kubectl --context="${CTX_CLUSTER1}" -n sample rollout status deploy/helloworld-v1 --timeout=180s
kubectl --context="${CTX_CLUSTER2}" -n sample rollout status deploy/helloworld-v2 --timeout=180s
kubectl --context="${CTX_CLUSTER1}" -n sample rollout status deploy/sleep --timeout=180s
kubectl --context="${CTX_CLUSTER2}" -n sample rollout status deploy/sleep --timeout=180s

for ctx in "${CTX_CLUSTER1}" "${CTX_CLUSTER2}"; do
  echo "=== Requests from ${ctx} ==="
  SLEEP_POD="$(kubectl --context="${ctx}" -n sample get pod -l app=sleep -o jsonpath='{.items[0].metadata.name}')"
  for _ in $(seq 1 12); do
    kubectl --context="${ctx}" -n sample exec -c sleep "${SLEEP_POD}" -- curl -sS helloworld.sample:5000/hello
  done
done
