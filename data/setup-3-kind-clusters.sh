#!/bin/bash
set -e

# Local equivalent of setup-3-3n-gke-clusters.sh: three single-node Kind
# clusters on one Docker host, wired up as a flat pod network so pod IPs are
# directly routable cluster-to-cluster (the same property GKE VPC-native
# routing gives us for free).

CLUSTER1_NAME="cluster-1"
CLUSTER2_NAME="cluster-2"
CLUSTER3_NAME="cluster-3"

CLUSTER1_POD_RANGE="10.10.0.0/16"
CLUSTER2_POD_RANGE="10.20.0.0/16"
CLUSTER3_POD_RANGE="10.30.0.0/16"

CLUSTER1_SVC_RANGE="10.255.10.0/24"
CLUSTER2_SVC_RANGE="10.255.20.0/24"
CLUSTER3_SVC_RANGE="10.255.30.0/24"

# MetalLB address-pool ranges, one per cluster, carved out of the shared
# "kind" Docker bridge network (172.18.0.0/16) using a distinct 3rd octet per
# cluster - the pattern Istio's own samples/kind-lb/setupkind.sh uses.
CLUSTER1_LB_RANGE="172.18.253.200-172.18.253.240"
CLUSTER2_LB_RANGE="172.18.254.200-172.18.254.240"
CLUSTER3_LB_RANGE="172.18.255.200-172.18.255.240"

REMOTE_CONTEXT1="kind-${CLUSTER1_NAME}"
REMOTE_CONTEXT2="kind-${CLUSTER2_NAME}"
REMOTE_CONTEXT3="kind-${CLUSTER3_NAME}"

create_cluster() {
  local name=$1 pod_range=$2 svc_range=$3
  echo "=== Creating Kind cluster ${name} (pods ${pod_range}, services ${svc_range}) ==="
  kind create cluster --name "${name}" --config - <<EOF
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
networking:
  podSubnet: "${pod_range}"
  serviceSubnet: "${svc_range}"
  disableDefaultCNI: false
nodes:
- role: control-plane
EOF
}

create_cluster "$CLUSTER1_NAME" "$CLUSTER1_POD_RANGE" "$CLUSTER1_SVC_RANGE"
create_cluster "$CLUSTER2_NAME" "$CLUSTER2_POD_RANGE" "$CLUSTER2_SVC_RANGE"
create_cluster "$CLUSTER3_NAME" "$CLUSTER3_POD_RANGE" "$CLUSTER3_SVC_RANGE"

echo ""
echo "=== Wiring up flat pod-network routing between clusters ==="
# All Kind clusters share the same "kind" Docker bridge network by default, so
# every node container can already reach every other node container by its
# Docker IP. What's missing is each node's *route* to the other clusters' pod
# CIDRs — GKE's VPC does this automatically via VPC-native routing; on Kind we
# add it by hand with one `ip route` per (node, remote pod CIDR) pair.

ALL_CLUSTERS=("$CLUSTER1_NAME" "$CLUSTER2_NAME" "$CLUSTER3_NAME")
ALL_CONTEXTS=("$REMOTE_CONTEXT1" "$REMOTE_CONTEXT2" "$REMOTE_CONTEXT3")

# Wait for each node to have a real podCIDR assigned before reading it.
for i in "${!ALL_CLUSTERS[@]}"; do
  ctx="${ALL_CONTEXTS[$i]}"
  for node in $(kind get nodes --name "${ALL_CLUSTERS[$i]}"); do
    for attempt in $(seq 1 30); do
      podcidr=$(kubectl --context "$ctx" get node "$node" -o jsonpath='{.spec.podCIDR}' 2>/dev/null || true)
      [ -n "$podcidr" ] && break
      sleep 2
    done
  done
done

for i in "${!ALL_CLUSTERS[@]}"; do
  src_cluster="${ALL_CLUSTERS[$i]}"
  src_ctx="${ALL_CONTEXTS[$i]}"
  for src_node in $(kind get nodes --name "$src_cluster"); do
    for j in "${!ALL_CLUSTERS[@]}"; do
      [ "$i" = "$j" ] && continue
      dst_cluster="${ALL_CLUSTERS[$j]}"
      dst_ctx="${ALL_CONTEXTS[$j]}"
      for dst_node in $(kind get nodes --name "$dst_cluster"); do
        dst_podcidr=$(kubectl --context "$dst_ctx" get node "$dst_node" -o jsonpath='{.spec.podCIDR}')
        dst_ip=$(docker inspect -f '{{ .NetworkSettings.Networks.kind.IPAddress }}' "$dst_node")
        echo "  ${src_node}: route ${dst_podcidr} via ${dst_ip} (${dst_node})"
        docker exec "$src_node" ip route replace "$dst_podcidr" via "$dst_ip"
      done
    done
  done
done

echo ""
echo "=== Installing MetalLB on all three clusters ==="
# Kind has no built-in LoadBalancer provider. cloud-provider-kind is the usual
# fix for a single cluster, but it always publishes a LoadBalancer Service's
# ports onto the host at their literal port numbers - with three clusters all
# running Istio's east-west gateway on the same fixed ports (15021/15008/15012),
# only the first cluster's proxy container can ever bind those host ports and
# the other two fail with "port already allocated". MetalLB sidesteps this
# entirely: it hands out IPs via L2/ARP inside the shared Docker network and
# never touches host ports, so all three clusters can have their own east-west
# gateway address at the same time. This mirrors Istio's own
# samples/kind-lb/setupkind.sh approach (one address pool per cluster, keyed
# off a distinct 3rd octet of the shared Docker network's subnet).
METALLB_VERSION="v0.14.9"
CLUSTER_CONTEXT_RANGES=(
  "${REMOTE_CONTEXT1}:${CLUSTER1_LB_RANGE}"
  "${REMOTE_CONTEXT2}:${CLUSTER2_LB_RANGE}"
  "${REMOTE_CONTEXT3}:${CLUSTER3_LB_RANGE}"
)

for pair in "${CLUSTER_CONTEXT_RANGES[@]}"; do
  ctx="${pair%%:*}"
  echo "--- metallb-native on ${ctx} ---"
  kubectl --context "$ctx" apply -f "https://raw.githubusercontent.com/metallb/metallb/${METALLB_VERSION}/config/manifests/metallb-native.yaml"
done

for pair in "${CLUSTER_CONTEXT_RANGES[@]}"; do
  ctx="${pair%%:*}"
  echo "--- waiting for metallb pods on ${ctx} ---"
  kubectl --context "$ctx" wait -n metallb-system pod -l app=metallb --for=condition=Ready --timeout=120s
done

for pair in "${CLUSTER_CONTEXT_RANGES[@]}"; do
  ctx="${pair%%:*}"
  range="${pair##*:}"
  echo "--- ${ctx} address pool ${range} ---"
  kubectl --context "$ctx" apply -f - <<EOF
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: address-pool
  namespace: metallb-system
spec:
  addresses:
  - ${range}
---
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: l2-adv
  namespace: metallb-system
EOF
done

echo ""
echo "All three Kind clusters created, flat-routed to each other, and have MetalLB ready"
echo ""
echo "Kubeconfig contexts:"
echo "  REMOTE_CONTEXT1=$REMOTE_CONTEXT1"
echo "  REMOTE_CONTEXT2=$REMOTE_CONTEXT2"
echo "  REMOTE_CONTEXT3=$REMOTE_CONTEXT3"
echo ""
echo "Pod CIDRs (now routed cluster-to-cluster - no NAT in the way):"
echo "  ${CLUSTER1_NAME}: $CLUSTER1_POD_RANGE"
echo "  ${CLUSTER2_NAME}: $CLUSTER2_POD_RANGE"
echo "  ${CLUSTER3_NAME}: $CLUSTER3_POD_RANGE"
echo ""
echo "MetalLB LoadBalancer IP pools:"
echo "  ${CLUSTER1_NAME}: $CLUSTER1_LB_RANGE"
echo "  ${CLUSTER2_NAME}: $CLUSTER2_LB_RANGE"
echo "  ${CLUSTER3_NAME}: $CLUSTER3_LB_RANGE"
echo ""
echo "Export contexts for subsequent scripts:"
echo "  export REMOTE_CONTEXT1=$REMOTE_CONTEXT1"
echo "  export REMOTE_CONTEXT2=$REMOTE_CONTEXT2"
echo "  export REMOTE_CONTEXT3=$REMOTE_CONTEXT3"
