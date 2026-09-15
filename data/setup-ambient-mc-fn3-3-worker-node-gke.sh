#!/bin/bash
set -e  # Exit on any error

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Logging functions
log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

log_section() {
    echo -e "\n${YELLOW}==== $1 ====${NC}"
}

# Check required environment variables
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

# Set up environment variables
setup_env() {
    log_section "Setting Up Environment Variables"

    export ISTIO_VERSION=1.31.0
    export ISTIO_IMAGE=${ISTIO_VERSION}-solo
    export REPO=us-docker.pkg.dev/soloio-img/istio;
    export HELM_REPO=us-docker.pkg.dev/soloio-img/istio-helm;
    
    # GKE cluster names (must match setup-3-3n-gke-clusters.sh)
    export REMOTE_CLUSTER1="glau-cluster-1"
    export REMOTE_CLUSTER2="glau-cluster-2"
    export REMOTE_CLUSTER3="glau-cluster-3"

    # GKE zones (must match setup-3-3n-gke-clusters.sh)
    export CLUSTER1_ZONE="us-central1-a"
    export CLUSTER2_ZONE="us-central1-b"
    export CLUSTER3_ZONE="us-central1-c"

    # GKE kubeconfig contexts (zone-based for zonal clusters)
    export PROJECT_ID="field-engineering-us"
    export REMOTE_CONTEXT1="gke_${PROJECT_ID}_${CLUSTER1_ZONE}_${REMOTE_CLUSTER1}"
    export REMOTE_CONTEXT2="gke_${PROJECT_ID}_${CLUSTER2_ZONE}_${REMOTE_CLUSTER2}"
    export REMOTE_CONTEXT3="gke_${PROJECT_ID}_${CLUSTER3_ZONE}_${REMOTE_CLUSTER3}"

    # Shared flat network across all clusters (GKE VPC-native routing enables direct pod-to-pod connectivity)
    export NETWORK="flat-network"

    log_success "Environment variables configured"
    log_info "Istio Version: ${ISTIO_VERSION}"
    log_info "Remote Contexts: ${REMOTE_CONTEXT1}, ${REMOTE_CONTEXT2}, ${REMOTE_CONTEXT3}"
}

# Install istioctl
install_istioctl() {
    log_section "Installing istioctl"
    
    bash <(curl -sSfL https://raw.githubusercontent.com/solo-io/gloo-mesh-use-cases/main/gloo-mesh/install-istioctl.sh)
    export PATH=${HOME}/.istioctl/bin:${PATH}
    
    log_success "istioctl installed"
}

# Install Istio components
install_istio() {
    log_section "Installing Istio"
    
    # Download Istio
    log_info "Downloading Istio ${ISTIO_VERSION}..."
    curl -L https://istio.io/downloadIstio | ISTIO_VERSION=${ISTIO_VERSION} sh -
    cd istio-${ISTIO_VERSION}
    
    # Create certificates
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

    GKE_CONTEXTS=($REMOTE_CONTEXT1 $REMOTE_CONTEXT2 $REMOTE_CONTEXT3)
    for ctx in "${GKE_CONTEXTS[@]}"; do
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

# Install Gateway API
install_gateway_api() {
    log_section "Installing Kubernetes Gateway API"
    
    for ctx in $REMOTE_CONTEXT1 $REMOTE_CONTEXT2 $REMOTE_CONTEXT3; do
        log_info "Installing Gateway API on ${ctx}..."
        kubectl --context=$ctx apply -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.5.1/standard-install.yaml
    done
    
    log_success "Gateway API installed on all clusters"
}

# Allow system-node-critical and system-cluster-critical pods in istio-system
# GKE rejects pods using these priority classes unless the namespace has a matching ResourceQuota
install_critical_pods_quota() {
    log_section "Installing Critical Pods ResourceQuota"

    for ctx in $REMOTE_CONTEXT1 $REMOTE_CONTEXT2 $REMOTE_CONTEXT3; do
        log_info "Creating istio-system namespace and ResourceQuota on ${ctx}..."
        kubectl create namespace istio-system --dry-run=client -o yaml | kubectl --context=${ctx} apply -f -
        kubectl --context=${ctx} apply -f - <<EOF
apiVersion: v1
kind: ResourceQuota
metadata:
  name: gcp-critical-pods
  namespace: istio-system
spec:
  hard:
    pods: 1G
  scopeSelector:
    matchExpressions:
    - operator: In
      scopeName: PriorityClass
      values:
      - system-node-critical
      - system-cluster-critical
EOF
    done

    log_success "Critical pods ResourceQuota installed on all clusters"
}

# Install Istio base
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
    
    # Verify CRDs
    for ctx in $REMOTE_CONTEXT1 $REMOTE_CONTEXT2 $REMOTE_CONTEXT3; do
        log_info "Verifying CRDs on ${ctx}..."
        kubectl get crds -l app.kubernetes.io/instance=istio-base --context ${ctx}
    done
    
    log_success "Istio base installed on all clusters"
}

# Install istiod
install_istiod() {
    log_section "Installing istiod"
    
    log_info "Installing istiod on ${REMOTE_CONTEXT1}..."
    helm upgrade --install istiod oci://${HELM_REPO}/istiod \
        --namespace istio-system \
        --kube-context ${REMOTE_CONTEXT1} \
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
    clusterName: "${REMOTE_CLUSTER1}"
  network: "${NETWORK}"
  tag: ${ISTIO_IMAGE}
meshConfig:
  accessLogFile: /dev/stdout
  defaultConfig:
    proxyMetadata:
      ISTIO_META_DNS_AUTO_ALLOCATE: "true"
      ISTIO_META_DNS_CAPTURE: "true"
  #trustDomain: "${REMOTE_CLUSTER1}.local"
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

    log_info "Installing istiod on ${REMOTE_CONTEXT2}..."
    helm upgrade --install istiod oci://${HELM_REPO}/istiod \
        --namespace istio-system \
        --kube-context ${REMOTE_CONTEXT2} \
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
    clusterName: "${REMOTE_CLUSTER2}"
  network: "${NETWORK}"
  tag: ${ISTIO_IMAGE}
meshConfig:
  accessLogFile: /dev/stdout
  defaultConfig:
    proxyMetadata:
      ISTIO_META_DNS_AUTO_ALLOCATE: "true"
      ISTIO_META_DNS_CAPTURE: "true"
  #trustDomain: "${REMOTE_CLUSTER2}.local"
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

    log_info "Installing istiod on ${REMOTE_CONTEXT3}..."
    helm upgrade --install istiod oci://${HELM_REPO}/istiod \
        --namespace istio-system \
        --kube-context ${REMOTE_CONTEXT3} \
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
    clusterName: "${REMOTE_CLUSTER3}"
  network: "${NETWORK}"
  tag: ${ISTIO_IMAGE}
meshConfig:
  accessLogFile: /dev/stdout
  defaultConfig:
    proxyMetadata:
      ISTIO_META_DNS_AUTO_ALLOCATE: "true"
      ISTIO_META_DNS_CAPTURE: "true"
  #trustDomain: "${REMOTE_CLUSTER3}.local"
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
    
    log_success "istiod installed on all clusters"
}

# Install CNI
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
  platform: gke
profile: ambient
EOF
    done
    
    log_success "Istio CNI installed on all clusters"
}

# Install ztunnel
install_ztunnel() {
    log_section "Installing ztunnel"
    
    log_info "Installing ztunnel on ${REMOTE_CONTEXT1}..."
    helm upgrade --install ztunnel oci://${HELM_REPO}/ztunnel \
        --namespace istio-system \
        --kube-context ${REMOTE_CONTEXT1} \
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
  clusterName: ${REMOTE_CLUSTER1}
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

    log_info "Installing ztunnel on ${REMOTE_CONTEXT2}..."
    helm upgrade --install ztunnel oci://${HELM_REPO}/ztunnel \
        --namespace istio-system \
        --kube-context ${REMOTE_CONTEXT2} \
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
  clusterName: ${REMOTE_CLUSTER2}
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

    log_info "Installing ztunnel on ${REMOTE_CONTEXT3}..."
    helm upgrade --install ztunnel oci://${HELM_REPO}/ztunnel \
        --namespace istio-system \
        --kube-context ${REMOTE_CONTEXT3} \
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
  clusterName: ${REMOTE_CLUSTER3}
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
    
    log_success "ztunnel installed on all clusters"
}

# Configure network labels
configure_network_labels() {
    log_section "Configuring Network Labels"
    
    kubectl --context=$REMOTE_CONTEXT1 label namespace istio-system topology.istio.io/network=${NETWORK} --overwrite
    kubectl --context=$REMOTE_CONTEXT2 label namespace istio-system topology.istio.io/network=${NETWORK} --overwrite
    kubectl --context=$REMOTE_CONTEXT3 label namespace istio-system topology.istio.io/network=${NETWORK} --overwrite
    
    log_success "Network labels configured"
}

# Link clusters
link_clusters() {
    log_section "Linking Clusters"
    
    # Create eastwest namespaces and expose
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
    
    # Wait for gateways to be programmed
    log_info "Waiting for eastwest gateways to be programmed..."
    for ctx in $REMOTE_CONTEXT1 $REMOTE_CONTEXT2 $REMOTE_CONTEXT3; do
        log_info "Waiting for eastwest gateway on ${ctx}..."
        timeout=300  # 5 minutes timeout
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
            kubectl get gateway istio-eastwest -n istio-eastwest --context $ctx -o yaml
            exit 1
        fi
    done
    
    # Verify gateways are ready
    for ctx in $REMOTE_CONTEXT1 $REMOTE_CONTEXT2 $REMOTE_CONTEXT3; do
        log_info "Final gateway status on ${ctx}:"
        kubectl get gateway -n istio-eastwest --context $ctx
    done
    
    # Link all three clusters together
    log_info "Linking all three clusters..."
    istioctl multicluster link \
        --contexts=$REMOTE_CONTEXT1,$REMOTE_CONTEXT2,$REMOTE_CONTEXT3 \
        -n istio-eastwest
    
    # Check multicluster setup
    log_info "Checking multicluster connectivity..."
    istioctl multicluster check --contexts="$REMOTE_CONTEXT1,$REMOTE_CONTEXT2,$REMOTE_CONTEXT3"
    
    log_success "All clusters linked successfully"
}

# Verify GKE node topology labels (GKE sets these automatically; we just confirm)
verify_node_labels() {
    log_section "Verifying Node Topology Labels"

    for ctx in $REMOTE_CONTEXT1 $REMOTE_CONTEXT2 $REMOTE_CONTEXT3; do
        log_info "Node topology labels on ${ctx}:"
        kubectl --context $ctx get nodes \
            -o custom-columns='NAME:.metadata.name,REGION:.metadata.labels.topology\.kubernetes\.io/region,ZONE:.metadata.labels.topology\.kubernetes\.io/zone'
    done

    log_success "Node topology labels verified"
}

# Main execution
main() {
    log_info "Starting Istio Ambient Mesh Multi-Cluster Setup (3 Clusters)"
    log_info "This script will set up a three-cluster Istio Ambient Mesh environment"
    
    check_env_vars
    setup_env
    install_istioctl
    install_istio
    install_gateway_api
    install_critical_pods_quota
    install_istio_base
    install_istiod
    install_cni
    install_ztunnel
    configure_network_labels
    link_clusters
    verify_node_labels
    
    log_success "🎉 Istio Ambient Mesh three-cluster setup completed successfully!"
    echo
    log_info "Next steps:"
    echo "  1. Check multicluster connectivity: istioctl multicluster check --contexts=\"$REMOTE_CONTEXT1,$REMOTE_CONTEXT2,$REMOTE_CONTEXT3\""
    echo "  2. Monitor services: kubectl get pods -A --context $REMOTE_CONTEXT1"
    echo "  3. Monitor services: kubectl get pods -A --context $REMOTE_CONTEXT2"
    echo "  4. Monitor services: kubectl get pods -A --context $REMOTE_CONTEXT3"
    echo "  5. Check eastwest gateways: kubectl get gateway -n istio-eastwest --context $REMOTE_CONTEXT1"
    echo "  6. Check eastwest gateways: kubectl get gateway -n istio-eastwest --context $REMOTE_CONTEXT2"
    echo "  7. Check eastwest gateways: kubectl get gateway -n istio-eastwest --context $REMOTE_CONTEXT3"
    echo
    log_info "Environment variables are exported. Source ~/.bashrc or restart your shell."
}

# Run main function
main "$@"