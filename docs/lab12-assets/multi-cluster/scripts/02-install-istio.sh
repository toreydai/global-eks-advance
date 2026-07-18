#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/env.sh"

aws eks update-kubeconfig --region "${AWS_REGION}" --name "${CLUSTER1}" --alias "${CTX_CLUSTER1}"
aws eks update-kubeconfig --region "${AWS_REGION}" --name "${CLUSTER2}" --alias "${CTX_CLUSTER2}"

kubectl --context="${CTX_CLUSTER1}" create namespace istio-system --dry-run=client -o yaml | kubectl --context="${CTX_CLUSTER1}" apply -f -
kubectl --context="${CTX_CLUSTER2}" create namespace istio-system --dry-run=client -o yaml | kubectl --context="${CTX_CLUSTER2}" apply -f -

CERT_DIR="${ROOT_DIR}/.work/certs"
rm -rf "${CERT_DIR}"
mkdir -p "${CERT_DIR}"
pushd "${CERT_DIR}" >/dev/null
make -f "${TOOLS_DIR}/istio-${ISTIO_VERSION}/tools/certs/Makefile.selfsigned.mk" root-ca
make -f "${TOOLS_DIR}/istio-${ISTIO_VERSION}/tools/certs/Makefile.selfsigned.mk" cluster1-cacerts
make -f "${TOOLS_DIR}/istio-${ISTIO_VERSION}/tools/certs/Makefile.selfsigned.mk" cluster2-cacerts

kubectl --context="${CTX_CLUSTER1}" -n istio-system create secret generic cacerts \
  --from-file=cluster1/ca-cert.pem \
  --from-file=cluster1/ca-key.pem \
  --from-file=cluster1/root-cert.pem \
  --from-file=cluster1/cert-chain.pem \
  --dry-run=client -o yaml | kubectl --context="${CTX_CLUSTER1}" apply -f -

kubectl --context="${CTX_CLUSTER2}" -n istio-system create secret generic cacerts \
  --from-file=cluster2/ca-cert.pem \
  --from-file=cluster2/ca-key.pem \
  --from-file=cluster2/root-cert.pem \
  --from-file=cluster2/cert-chain.pem \
  --dry-run=client -o yaml | kubectl --context="${CTX_CLUSTER2}" apply -f -
popd >/dev/null

kubectl --context="${CTX_CLUSTER1}" label namespace istio-system topology.istio.io/network=network1 --overwrite
kubectl --context="${CTX_CLUSTER2}" label namespace istio-system topology.istio.io/network=network2 --overwrite

cat > "${ROOT_DIR}/.work/cluster1.yaml" <<EOF
apiVersion: install.istio.io/v1alpha1
kind: IstioOperator
spec:
  values:
    global:
      meshID: mesh1
      multiCluster:
        clusterName: cluster1
      network: network1
EOF

istioctl install -y --set values.pilot.env.EXTERNAL_ISTIOD=true --context="${CTX_CLUSTER1}" -f "${ROOT_DIR}/.work/cluster1.yaml"

"${TOOLS_DIR}/istio-${ISTIO_VERSION}/samples/multicluster/gen-eastwest-gateway.sh" \
  --network network1 | istioctl --context="${CTX_CLUSTER1}" install -y -f -

kubectl --context="${CTX_CLUSTER1}" apply -n istio-system -f \
  "${TOOLS_DIR}/istio-${ISTIO_VERSION}/samples/multicluster/expose-istiod.yaml"

DISCOVERY_ADDRESS=""
for _ in $(seq 1 60); do
  DISCOVERY_ADDRESS="$(kubectl --context="${CTX_CLUSTER1}" -n istio-system get svc istio-eastwestgateway -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)"
  [[ -n "${DISCOVERY_ADDRESS}" ]] && break
  sleep 10
done

if [[ -z "${DISCOVERY_ADDRESS}" ]]; then
  echo "istio-eastwestgateway did not get a load balancer hostname" >&2
  exit 1
fi

cat > "${ROOT_DIR}/.work/cluster2.yaml" <<EOF
apiVersion: install.istio.io/v1alpha1
kind: IstioOperator
spec:
  profile: remote
  values:
    istiodRemote:
      injectionPath: /inject/cluster/cluster2/net/network2
    global:
      remotePilotAddress: ${DISCOVERY_ADDRESS}
EOF

istioctl install -y --context="${CTX_CLUSTER2}" -f "${ROOT_DIR}/.work/cluster2.yaml"

mapfile -t DISCOVERY_IPS < <(getent ahostsv4 "${DISCOVERY_ADDRESS}" | awk '{print $1}' | sort -u)
if [[ "${#DISCOVERY_IPS[@]}" -eq 0 ]]; then
  echo "could not resolve ${DISCOVERY_ADDRESS}" >&2
  exit 1
fi

kubectl --context="${CTX_CLUSTER2}" -n istio-system delete svc istiod --ignore-not-found
cat > "${ROOT_DIR}/.work/remote-istiod-service.yaml" <<EOF
apiVersion: v1
kind: Service
metadata:
  name: istiod
  namespace: istio-system
spec:
  type: ClusterIP
  ports:
    - name: tcp-istiod
      port: 15012
      protocol: TCP
      targetPort: 15012
    - name: tcp-webhook
      port: 443
      protocol: TCP
      targetPort: 15017
---
apiVersion: discovery.k8s.io/v1
kind: EndpointSlice
metadata:
  name: istiod-manual-1
  namespace: istio-system
  labels:
    kubernetes.io/service-name: istiod
addressType: IPv4
ports:
  - name: tcp-istiod
    protocol: TCP
    port: 15012
  - name: tcp-webhook
    protocol: TCP
    port: 15017
endpoints:
EOF
for ip in "${DISCOVERY_IPS[@]}"; do
  cat >> "${ROOT_DIR}/.work/remote-istiod-service.yaml" <<EOF
  - addresses:
      - ${ip}
EOF
done
kubectl --context="${CTX_CLUSTER2}" apply -f "${ROOT_DIR}/.work/remote-istiod-service.yaml"

kubectl --context="${CTX_CLUSTER2}" -n istio-system create configmap istio-ca-root-cert \
  --from-file=root-cert.pem="${CERT_DIR}/cluster2/root-cert.pem" \
  --dry-run=client -o yaml | kubectl --context="${CTX_CLUSTER2}" apply -f -

kubectl --context="${CTX_CLUSTER2}" patch mutatingwebhookconfiguration istio-sidecar-injector --type=json \
  -p='[{"op":"replace","path":"/webhooks/0/failurePolicy","value":"Ignore"},{"op":"replace","path":"/webhooks/1/failurePolicy","value":"Ignore"},{"op":"replace","path":"/webhooks/2/failurePolicy","value":"Ignore"},{"op":"replace","path":"/webhooks/3/failurePolicy","value":"Ignore"}]'

istioctl create-remote-secret --context="${CTX_CLUSTER2}" --name=cluster2 | \
  kubectl --context="${CTX_CLUSTER1}" apply -f -

"${TOOLS_DIR}/istio-${ISTIO_VERSION}/samples/multicluster/gen-eastwest-gateway.sh" \
  --network network2 > "${ROOT_DIR}/.work/eastwest-network2.yaml"
istioctl manifest generate -f "${ROOT_DIR}/.work/eastwest-network2.yaml" | \
  kubectl --context="${CTX_CLUSTER2}" apply -f -
kubectl --context="${CTX_CLUSTER2}" -n istio-system patch deploy istio-eastwestgateway \
  --patch-file "${ROOT_DIR}/configs/remote-eastwestgateway-patch.yaml"
kubectl --context="${CTX_CLUSTER2}" -n istio-system rollout status deploy/istio-eastwestgateway --timeout=180s

kubectl --context="${CTX_CLUSTER1}" apply -n istio-system -f \
  "${TOOLS_DIR}/istio-${ISTIO_VERSION}/samples/multicluster/expose-services.yaml"

kubectl --context="${CTX_CLUSTER1}" -n istio-system get pods,svc
kubectl --context="${CTX_CLUSTER2}" -n istio-system get pods,svc
