#!/bin/bash
set -e

# Mirrors the resource names created by setup-3-3n-gke-clusters.sh

# GCP Configuration
PROJECT_ID="field-engineering-us"

# Network
NETWORK="solo-vpc"

# Cluster 1 - us-central1-a
CLUSTER1_NAME="glau-cluster-1"
CLUSTER1_ZONE="us-central1-a"
CLUSTER1_SUBNET="solo-subnet-cluster-1"

# Cluster 2 - us-central1-b
CLUSTER2_NAME="glau-cluster-2"
CLUSTER2_ZONE="us-central1-b"
CLUSTER2_SUBNET="solo-subnet-cluster-2"

# Cluster 3 - us-central1-c
CLUSTER3_NAME="glau-cluster-3"
CLUSTER3_ZONE="us-central1-c"
CLUSTER3_SUBNET="solo-subnet-cluster-3"

# Kubeconfig contexts (zonal cluster context uses zone, not region)
REMOTE_CONTEXT1="gke_${PROJECT_ID}_${CLUSTER1_ZONE}_${CLUSTER1_NAME}"
REMOTE_CONTEXT2="gke_${PROJECT_ID}_${CLUSTER2_ZONE}_${CLUSTER2_NAME}"
REMOTE_CONTEXT3="gke_${PROJECT_ID}_${CLUSTER3_ZONE}_${CLUSTER3_NAME}"

echo "Setting project..."
gcloud config set project $PROJECT_ID

echo "Deleting the three GKE clusters (this permanently deletes real cloud infrastructure)..."
gcloud container clusters delete $CLUSTER1_NAME --zone=$CLUSTER1_ZONE --project=$PROJECT_ID --quiet
gcloud container clusters delete $CLUSTER2_NAME --zone=$CLUSTER2_ZONE --project=$PROJECT_ID --quiet
gcloud container clusters delete $CLUSTER3_NAME --zone=$CLUSTER3_ZONE --project=$PROJECT_ID --quiet

echo "Deleting the cross-cluster firewall rule..."
gcloud compute firewall-rules delete solo-allow-cross-cluster --project=$PROJECT_ID --quiet

echo "Deleting the per-cluster subnets..."
gcloud compute networks subnets delete $CLUSTER1_SUBNET --region=us-central1 --project=$PROJECT_ID --quiet
gcloud compute networks subnets delete $CLUSTER2_SUBNET --region=us-central1 --project=$PROJECT_ID --quiet
gcloud compute networks subnets delete $CLUSTER3_SUBNET --region=us-central1 --project=$PROJECT_ID --quiet

# Only delete the VPC itself if nothing else in the project uses it — solo-vpc is a shared,
# reusable network, not something this lab necessarily owns exclusively. Uncomment if you're sure:
# echo "Deleting the VPC network..."
# gcloud compute networks delete $NETWORK --project=$PROJECT_ID --quiet

echo "Removing local kubeconfig contexts..."
kubectl config delete-context $REMOTE_CONTEXT1 2>/dev/null || true
kubectl config delete-context $REMOTE_CONTEXT2 2>/dev/null || true
kubectl config delete-context $REMOTE_CONTEXT3 2>/dev/null || true

echo ""
echo "Cleanup complete."
