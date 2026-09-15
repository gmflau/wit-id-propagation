#!/bin/bash
set -e

# GCP Configuration
PROJECT_ID="field-engineering-us"
MACHINE_TYPE="e2-standard-4"
NUM_NODES=3

# Labels
LABEL_KEY1="created_by"
LABEL_VALUE1="gilbert_lau"
LABEL_KEY2="team"
LABEL_VALUE2="ssa"
LABEL_KEY3="purpose"
LABEL_VALUE3="poc"

# Network
NETWORK="solo-vpc"

# Cluster 1 - us-central1-a
CLUSTER1_NAME="glau-cluster-1"
CLUSTER1_ZONE="us-central1-a"
CLUSTER1_SUBNET="solo-subnet-cluster-1"
CLUSTER1_NODE_RANGE="10.100.0.0/22"
CLUSTER1_POD_RANGE="10.10.0.0/16"
CLUSTER1_SVC_RANGE="10.255.10.0/24"
CLUSTER1_POD_RANGE_NAME="pods-cluster-1"
CLUSTER1_SVC_RANGE_NAME="services-cluster-1"

# Cluster 2 - us-central1-b
CLUSTER2_NAME="glau-cluster-2"
CLUSTER2_ZONE="us-central1-b"
CLUSTER2_SUBNET="solo-subnet-cluster-2"
CLUSTER2_NODE_RANGE="10.101.0.0/22"
CLUSTER2_POD_RANGE="10.20.0.0/16"
CLUSTER2_SVC_RANGE="10.255.20.0/24"
CLUSTER2_POD_RANGE_NAME="pods-cluster-2"
CLUSTER2_SVC_RANGE_NAME="services-cluster-2"

# Cluster 3 - us-central1-c
CLUSTER3_NAME="glau-cluster-3"
CLUSTER3_ZONE="us-central1-c"
CLUSTER3_SUBNET="solo-subnet-cluster-3"
CLUSTER3_NODE_RANGE="10.102.0.0/22"
CLUSTER3_POD_RANGE="10.30.0.0/16"
CLUSTER3_SVC_RANGE="10.255.30.0/24"
CLUSTER3_POD_RANGE_NAME="pods-cluster-3"
CLUSTER3_SVC_RANGE_NAME="services-cluster-3"

# Kubeconfig contexts (zonal cluster context uses zone, not region)
REMOTE_CONTEXT1="gke_${PROJECT_ID}_${CLUSTER1_ZONE}_${CLUSTER1_NAME}"
REMOTE_CONTEXT2="gke_${PROJECT_ID}_${CLUSTER2_ZONE}_${CLUSTER2_NAME}"
REMOTE_CONTEXT3="gke_${PROJECT_ID}_${CLUSTER3_ZONE}_${CLUSTER3_NAME}"

echo "Authenticating and setting project..."
gcloud auth login
gcloud config set project $PROJECT_ID

echo "Creating VPC network..."
gcloud compute networks create $NETWORK --subnet-mode=custom || echo "Network $NETWORK already exists"

echo "Cleaning up any subnets created in wrong regions from prior runs..."
gcloud compute networks subnets delete solo-subnet-cluster-2 --region=us-east1 --quiet 2>/dev/null || true
gcloud compute networks subnets delete solo-subnet-cluster-3 --region=europe-west1 --quiet 2>/dev/null || true

echo "Creating subnets in us-central1..."

gcloud compute networks subnets create $CLUSTER1_SUBNET \
  --network=$NETWORK \
  --region=us-central1 \
  --range=$CLUSTER1_NODE_RANGE \
  --secondary-range=${CLUSTER1_POD_RANGE_NAME}=${CLUSTER1_POD_RANGE},${CLUSTER1_SVC_RANGE_NAME}=${CLUSTER1_SVC_RANGE} \
  || echo "Subnet $CLUSTER1_SUBNET already exists"

gcloud compute networks subnets create $CLUSTER2_SUBNET \
  --network=$NETWORK \
  --region=us-central1 \
  --range=$CLUSTER2_NODE_RANGE \
  --secondary-range=${CLUSTER2_POD_RANGE_NAME}=${CLUSTER2_POD_RANGE},${CLUSTER2_SVC_RANGE_NAME}=${CLUSTER2_SVC_RANGE} \
  || echo "Subnet $CLUSTER2_SUBNET already exists"

gcloud compute networks subnets create $CLUSTER3_SUBNET \
  --network=$NETWORK \
  --region=us-central1 \
  --range=$CLUSTER3_NODE_RANGE \
  --secondary-range=${CLUSTER3_POD_RANGE_NAME}=${CLUSTER3_POD_RANGE},${CLUSTER3_SVC_RANGE_NAME}=${CLUSTER3_SVC_RANGE} \
  || echo "Subnet $CLUSTER3_SUBNET already exists"

echo "Creating firewall rule for cross-cluster pod communication..."
gcloud compute firewall-rules create solo-allow-cross-cluster \
  --network=$NETWORK \
  --allow=tcp,udp,icmp \
  --source-ranges=${CLUSTER1_POD_RANGE},${CLUSTER2_POD_RANGE},${CLUSTER3_POD_RANGE},${CLUSTER1_NODE_RANGE},${CLUSTER2_NODE_RANGE},${CLUSTER3_NODE_RANGE} \
  --description="Allow cross-cluster pod and node communication for Istio ambient mesh" \
  || echo "Firewall rule already exists"

echo "Creating GKE cluster-1 in zone $CLUSTER1_ZONE..."
gcloud container clusters create $CLUSTER1_NAME \
  --image-type=COS_CONTAINERD \
  --zone=$CLUSTER1_ZONE \
  --network=$NETWORK \
  --subnetwork=$CLUSTER1_SUBNET \
  --cluster-secondary-range-name=$CLUSTER1_POD_RANGE_NAME \
  --services-secondary-range-name=$CLUSTER1_SVC_RANGE_NAME \
  --machine-type=$MACHINE_TYPE \
  --num-nodes=$NUM_NODES \
  --enable-ip-alias \
  --enable-secret-manager \
  --workload-pool=${PROJECT_ID}.svc.id.goog \
  --labels=${LABEL_KEY1}=${LABEL_VALUE1},${LABEL_KEY2}=${LABEL_VALUE2},${LABEL_KEY3}=${LABEL_VALUE3}

echo "Creating GKE cluster-2 in zone $CLUSTER2_ZONE..."
gcloud container clusters create $CLUSTER2_NAME \
  --image-type=COS_CONTAINERD \
  --zone=$CLUSTER2_ZONE \
  --network=$NETWORK \
  --subnetwork=$CLUSTER2_SUBNET \
  --cluster-secondary-range-name=$CLUSTER2_POD_RANGE_NAME \
  --services-secondary-range-name=$CLUSTER2_SVC_RANGE_NAME \
  --machine-type=$MACHINE_TYPE \
  --num-nodes=$NUM_NODES \
  --enable-ip-alias \
  --enable-secret-manager \
  --workload-pool=${PROJECT_ID}.svc.id.goog \
  --labels=${LABEL_KEY1}=${LABEL_VALUE1},${LABEL_KEY2}=${LABEL_VALUE2},${LABEL_KEY3}=${LABEL_VALUE3}

echo "Creating GKE cluster-3 in zone $CLUSTER3_ZONE..."
gcloud container clusters create $CLUSTER3_NAME \
  --image-type=COS_CONTAINERD \
  --zone=$CLUSTER3_ZONE \
  --network=$NETWORK \
  --subnetwork=$CLUSTER3_SUBNET \
  --cluster-secondary-range-name=$CLUSTER3_POD_RANGE_NAME \
  --services-secondary-range-name=$CLUSTER3_SVC_RANGE_NAME \
  --machine-type=$MACHINE_TYPE \
  --num-nodes=$NUM_NODES \
  --enable-ip-alias \
  --enable-secret-manager \
  --workload-pool=${PROJECT_ID}.svc.id.goog \
  --labels=${LABEL_KEY1}=${LABEL_VALUE1},${LABEL_KEY2}=${LABEL_VALUE2},${LABEL_KEY3}=${LABEL_VALUE3}

echo "Fetching kubeconfig credentials..."
gcloud container clusters get-credentials $CLUSTER1_NAME --zone=$CLUSTER1_ZONE --project=$PROJECT_ID
gcloud container clusters get-credentials $CLUSTER2_NAME --zone=$CLUSTER2_ZONE --project=$PROJECT_ID
gcloud container clusters get-credentials $CLUSTER3_NAME --zone=$CLUSTER3_ZONE --project=$PROJECT_ID

echo ""
echo "All three GKE zonal clusters created with $NUM_NODES nodes each"
echo ""
echo "Kubeconfig contexts:"
echo "  REMOTE_CONTEXT1=$REMOTE_CONTEXT1"
echo "  REMOTE_CONTEXT2=$REMOTE_CONTEXT2"
echo "  REMOTE_CONTEXT3=$REMOTE_CONTEXT3"
echo ""
echo "Pod CIDRs (GCP VPC routes these automatically - no manual ip route setup needed):"
echo "  glau-cluster-1: $CLUSTER1_POD_RANGE"
echo "  glau-cluster-2: $CLUSTER2_POD_RANGE"
echo "  glau-cluster-3: $CLUSTER3_POD_RANGE"
echo ""
echo "Export contexts for subsequent scripts:"
echo "  export REMOTE_CONTEXT1=$REMOTE_CONTEXT1"
echo "  export REMOTE_CONTEXT2=$REMOTE_CONTEXT2"
echo "  export REMOTE_CONTEXT3=$REMOTE_CONTEXT3"
