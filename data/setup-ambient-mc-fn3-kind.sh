#!/bin/bash
set -e  # Exit on any error

# Local (Kind) equivalent of setup-ambient-mc-fn3-3-worker-node-gke.sh: three
# Kind clusters, one flat network, linked as a Solo Istio ambient multicluster
# mesh. The Istio/agentgateway install values are unchanged from the GKE
# version - only cluster names/contexts and the two GKE-only steps
# (ResourceQuota for GKE priority classes, `platform: gke` on istio-cni) are
# dropped.

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

log_info()    { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $1"; }
log_section() { echo -e "\n${YELLOW}==== $1 ====${NC}"; }

check_env_vars() {
    log_section "Checking Environment Variables"

    if [ -z "$SOLO_LICENSE_KEY" ]; then
        log_error "SOLO_LICENSE_KEY is not set"
        exit 1
    fi

    if [ -z "$GLOO_MESH_LICENSE_KEY" ]; then
        log_error "GLOO_MESH_LICENSE_KEY is not set"
        exit 1
    fi

    log_success "Environment variables are set"
}

setup_env() {
    log_section "Setting Up Environment Variables"

    export ISTIO_VERSION=1.31.0
    export ISTIO_IMAGE=${ISTIO_VERSION}-solo
    export REPO=us-docker.pkg.dev/soloio-img/istio
    export HELM_REPO=us-docker.pkg.dev/soloio-img/istio-helm

    # Kind cluster names (must match setup-3-kind-clusters.sh)
    export REMOTE_CLUSTER1="cluster-1"
    export REMOTE_CLUSTER2="cluster-2"
    export REMOTE_CLUSTER3="cluster-3"

    # Kind kubeconfig contexts (kind always names them "kind-<cluster name>")
    export REMOTE_CONTEXT1="kind-${REMOTE_CLUSTER1}"
    export REMOTE_CONTEXT2="kind-${REMOTE_CLUSTER2}"
    export REMOTE_CONTEXT3="kind-${REMOTE_CLUSTER3}"

    # Shared flat network across all clusters (Kind pod CIDRs are routed
    # cluster-to-cluster by setup-3-kind-clusters.sh, so pods reach each other
    # directly - same property GKE VPC-native routing gives us)
    export NETWORK="flat-network"

    log_success "Environment variables configured"
    log_info "Istio Version: ${ISTIO_VERSION}"
    log_info "Remote Contexts: ${REMOTE_CONTEXT1}, ${REMOTE_CONTEXT2}, ${REMOTE_CONTEXT3}"
}

install_istioctl() {
    log_section "Installing istioctl"

    bash <(curl -sSfL https://raw.githubusercontent.com/solo-io/gloo-mesh-use-cases/main/gloo-mesh/install-istioctl.sh)
    export PATH=${HOME}/.istioctl/bin:${PATH}

    log_success "istioctl installed"
}

install_istio() {
    log_section "Installing Istio"

    log_info "Downloading Istio ${ISTIO_VERSION}..."
    curl -L https://istio.io/downloadIstio | ISTIO_VERSION=${ISTIO_VERSION} sh -
    cd istio-${ISTIO_VERSION}

    mkdir -p /tmp/good-ca

    # Root CA — generated ONCE, shared by all three clusters
    openssl genrsa -out /tmp/good-ca/root-key.pem 4096
    openssl req -new -x509 -key /tmp/good-ca/root-key.pem -out /tmp/good-ca/root-cert.pem -days 3650 \
      -subj "/O=Test Root CA"

    # Intermediate CA key + CSR — also generated ONCE, shared by all three clusters
    openssl genrsa -out /tmp/good-ca/ca-key.pem 4096
    openssl req -new -key /tmp/good-ca/ca-key.pem -out /tmp/good-ca/ca-csr.pem \
      -subj "/O=Test Intermediate CA"

    # Sign the intermediate with the CORRECT trust domain SAN
    cat > /tmp/good-ca/correct-san.cnf <<EOF
basicConstraints = critical, CA:TRUE, pathlen:0
keyUsage = critical, keyCertSign, cRLSign
subjectAltName = URI:spiffe://cluster.local
EOF

    openssl x509 -req -in /tmp/good-ca/ca-csr.pem \
      -CA /tmp/good-ca/root-cert.pem -CAkey /tmp/good-ca/root-key.pem -CAcreateserial \
      -out /tmp/good-ca/ca-cert.pem -days 3650 \
      -extfile /tmp/good-ca/correct-san.cnf

    cat /tmp/good-ca/ca-cert.pem /tmp/good-ca/root-cert.pem > /tmp/good-ca/cert-chain.pem

    KIND_CONTEXTS=($REMOTE_CONTEXT1 $REMOTE_CONTEXT2 $REMOTE_CONTEXT3)
    for ctx in "${KIND_CONTEXTS[@]}"; do
      echo "=== applying to $ctx ==="
      kubectl --context="$ctx" create namespace istio-system --dry-run=client -o yaml | kubectl --context="$ctx" apply -f -

      kubectl --context="$ctx" create secret generic cacerts -n istio-system \
        --from-file=/tmp/good-ca/ca-cert.pem \
        --from-file=/tmp/good-ca/ca-key.pem \
        --from-file=/tmp/good-ca/root-cert.pem \
        --from-file=/tmp/good-ca/cert-chain.pem \
        --dry-run=client -o yaml | kubectl --context="$ctx" apply -f -
    done

    log_success "Istio downloaded and certificates created"
}

install_gateway_api() {
    log_section "Installing Kubernetes Gateway API"

    for ctx in $REMOTE_CONTEXT1 $REMOTE_CONTEXT2 $REMOTE_CONTEXT3; do
        log_info "Installing Gateway API on ${ctx}..."
        kubectl --context=$ctx apply -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.5.1/standard-install.yaml
    done

    log_success "Gateway API installed on all clusters"
}

install_istio_base() {
    log_section "Installing Istio Base"

    for ctx in $REMOTE_CONTEXT1 $REMOTE_CONTEXT2 $REMOTE_CONTEXT3; do
        log_info "Installing istio-base on ${ctx}..."
        helm upgrade --install istio-base oci://${HELM_REPO}/base \
            --namespace istio-system \
            --create-namespace \
            --kube-context ${ctx} \
            --version ${ISTIO_IMAGE} \
            -f - <<EOF
defaultRevision: ""
profile: ambient
license:
  value: ${SOLO_LICENSE_KEY}
EOF
    done

    for ctx in $REMOTE_CONTEXT1 $REMOTE_CONTEXT2 $REMOTE_CONTEXT3; do
        log_info "Verifying CRDs on ${ctx}..."
        kubectl get crds -l app.kubernetes.io/instance=istio-base --context ${ctx}
    done

    log_success "Istio base installed on all clusters"
}

install_istiod() {
    log_section "Installing istiod"

    for pair in "${REMOTE_CONTEXT1}:${REMOTE_CLUSTER1}" "${REMOTE_CONTEXT2}:${REMOTE_CLUSTER2}" "${REMOTE_CONTEXT3}:${REMOTE_CLUSTER3}"; do
        ctx="${pair%%:*}"
        cluster="${pair##*:}"
        log_info "Installing istiod on ${ctx}..."
        helm upgrade --install istiod oci://${HELM_REPO}/istiod \
            --namespace istio-system \
            --kube-context ${ctx} \
            --version ${ISTIO_IMAGE} \
            -f - <<EOF
env:
  PILOT_ENABLE_IP_AUTOALLOCATE: "true"
  PEERING_ENABLE_FLAT_NETWORKS: "true"
  DISABLE_LEGACY_MULTICLUSTER: "true"
  # Required when meshConfig.trustDomain is set
  PILOT_SKIP_VALIDATE_TRUST_DOMAIN: "true"
global:
  hub: ${REPO}
  multiCluster:
    clusterName: "${cluster}"
  network: "${NETWORK}"
  tag: ${ISTIO_IMAGE}
meshConfig:
  accessLogFile: /dev/stdout
  defaultConfig:
    proxyMetadata:
      ISTIO_META_DNS_AUTO_ALLOCATE: "true"
      ISTIO_META_DNS_CAPTURE: "true"
  trustDomain: "cluster.local"
pilot:
  cni:
    namespace: istio-system
    enabled: true
platforms:
  peering:
    enabled: true
profile: ambient
license:
  value: ${GLOO_MESH_LICENSE_KEY}
EOF
    done

    log_success "istiod installed on all clusters"
}

install_cni() {
    log_section "Installing Istio CNI"

    for ctx in $REMOTE_CONTEXT1 $REMOTE_CONTEXT2 $REMOTE_CONTEXT3; do
        log_info "Installing istio-cni on ${ctx}..."
        helm upgrade --install istio-cni oci://${HELM_REPO}/cni \
            --namespace istio-system \
            --kube-context ${ctx} \
            --version ${ISTIO_IMAGE} \
            -f - <<EOF
ambient:
  dnsCapture: true
excludeNamespaces:
  - istio-system
  - kube-system
global:
  hub: ${REPO}
  tag: ${ISTIO_IMAGE}
profile: ambient
EOF
    done

    log_success "Istio CNI installed on all clusters"
}

install_ztunnel() {
    log_section "Installing ztunnel"

    for pair in "${REMOTE_CONTEXT1}:${REMOTE_CLUSTER1}" "${REMOTE_CONTEXT2}:${REMOTE_CLUSTER2}" "${REMOTE_CONTEXT3}:${REMOTE_CLUSTER3}"; do
        ctx="${pair%%:*}"
        cluster="${pair##*:}"
        log_info "Installing ztunnel on ${ctx}..."
        helm upgrade --install ztunnel oci://${HELM_REPO}/ztunnel \
            --namespace istio-system \
            --kube-context ${ctx} \
            --version ${ISTIO_IMAGE} \
            -f - <<EOF
configValidation: true
enabled: true
env:
  L7_ENABLED: "true"
  ENABLE_WORKLOAD_CLAIMS: "true"
  # Required when a unique trust domain is set for each cluster
  SKIP_VALIDATE_TRUST_DOMAIN: "true"
  VALIDATE_SPIFFE_TRUST_DOMAIN_NAMES: "STRICT"
hub: ${REPO}
istioNamespace: istio-system
multiCluster:
  clusterName: ${cluster}
namespace: istio-system
network: "${NETWORK}"
platforms:
  peering:
    enabled: true
profile: ambient
tag: ${ISTIO_IMAGE}
terminationGracePeriodSeconds: 29
variant: distroless
EOF
    done

    log_success "ztunnel installed on all clusters"
}

configure_network_labels() {
    log_section "Configuring Network Labels"

    kubectl --context=$REMOTE_CONTEXT1 label namespace istio-system topology.istio.io/network=${NETWORK} --overwrite
    kubectl --context=$REMOTE_CONTEXT2 label namespace istio-system topology.istio.io/network=${NETWORK} --overwrite
    kubectl --context=$REMOTE_CONTEXT3 label namespace istio-system topology.istio.io/network=${NETWORK} --overwrite

    log_success "Network labels configured"
}

link_clusters() {
    log_section "Linking Clusters"

    log_info "Waiting for istiod to be ready on ${REMOTE_CONTEXT1}..."
    kubectl --context=$REMOTE_CONTEXT1 rollout status deployment/istiod -n istio-system --timeout=300s
    log_info "Creating eastwest gateway on ${REMOTE_CONTEXT1}..."
    kubectl create namespace istio-eastwest --context $REMOTE_CONTEXT1 || true
    istioctl --context=$REMOTE_CONTEXT1 multicluster expose --namespace istio-eastwest

    log_info "Waiting for istiod to be ready on ${REMOTE_CONTEXT2}..."
    kubectl --context=$REMOTE_CONTEXT2 rollout status deployment/istiod -n istio-system --timeout=300s
    log_info "Creating eastwest gateway on ${REMOTE_CONTEXT2}..."
    kubectl create namespace istio-eastwest --context $REMOTE_CONTEXT2 || true
    istioctl --context=$REMOTE_CONTEXT2 multicluster expose --namespace istio-eastwest

    log_info "Waiting for istiod to be ready on ${REMOTE_CONTEXT3}..."
    kubectl --context=$REMOTE_CONTEXT3 rollout status deployment/istiod -n istio-system --timeout=300s
    log_info "Creating eastwest gateway on ${REMOTE_CONTEXT3}..."
    kubectl create namespace istio-eastwest --context $REMOTE_CONTEXT3 || true
    istioctl --context=$REMOTE_CONTEXT3 multicluster expose --namespace istio-eastwest

    log_info "Waiting for eastwest gateways to be programmed..."
    for ctx in $REMOTE_CONTEXT1 $REMOTE_CONTEXT2 $REMOTE_CONTEXT3; do
        log_info "Waiting for eastwest gateway on ${ctx}..."
        timeout=300
        while [ $timeout -gt 0 ]; do
            status=$(kubectl get gateway istio-eastwest -n istio-eastwest --context $ctx -o jsonpath='{.status.conditions[?(@.type=="Programmed")].status}' 2>/dev/null || echo "False")
            if [ "$status" = "True" ]; then
                log_success "Eastwest gateway on ${ctx} is programmed"
                break
            fi
            log_info "Gateway on ${ctx} not ready yet (status: ${status}), waiting..."
            sleep 10
            timeout=$((timeout-10))
        done

        if [ $timeout -le 0 ]; then
            log_error "Timeout waiting for eastwest gateway on ${ctx} to be programmed"
            log_error "Did ./data/setup-3-kind-clusters.sh finish installing MetalLB on all three clusters? Kind Gateway Services stay EXTERNAL-IP <pending> without a LoadBalancer provider."
            kubectl get gateway istio-eastwest -n istio-eastwest --context $ctx -o yaml
            exit 1
        fi
    done

    for ctx in $REMOTE_CONTEXT1 $REMOTE_CONTEXT2 $REMOTE_CONTEXT3; do
        log_info "Final gateway status on ${ctx}:"
        kubectl get gateway -n istio-eastwest --context $ctx
    done

    log_info "Linking all three clusters..."
    istioctl multicluster link \
        --contexts=$REMOTE_CONTEXT1,$REMOTE_CONTEXT2,$REMOTE_CONTEXT3 \
        -n istio-eastwest

    log_info "Checking multicluster connectivity..."
    istioctl multicluster check --contexts="$REMOTE_CONTEXT1,$REMOTE_CONTEXT2,$REMOTE_CONTEXT3"

    log_success "All clusters linked successfully"
}

main() {
    log_info "Starting Istio Ambient Mesh Multi-Cluster Setup (3 Kind clusters)"

    check_env_vars
    setup_env
    install_istioctl
    install_istio
    install_gateway_api
    install_istio_base
    install_istiod
    install_cni
    install_ztunnel
    configure_network_labels
    link_clusters

    log_success "🎉 Istio Ambient Mesh three-cluster setup completed successfully!"
    echo
    log_info "Next steps:"
    echo "  1. Check multicluster connectivity: istioctl multicluster check --contexts=\"$REMOTE_CONTEXT1,$REMOTE_CONTEXT2,$REMOTE_CONTEXT3\""
    echo "  2. Monitor services: kubectl get pods -A --context $REMOTE_CONTEXT1"
    echo "  3. Monitor services: kubectl get pods -A --context $REMOTE_CONTEXT2"
    echo "  4. Monitor services: kubectl get pods -A --context $REMOTE_CONTEXT3"
    echo
    log_info "Environment variables are exported. Source ~/.bashrc or restart your shell."
}

main "$@"
