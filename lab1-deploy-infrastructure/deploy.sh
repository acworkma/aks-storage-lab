#!/bin/bash

# AKS Storage Lab - Infrastructure Deployment Script
# This script deploys an AKS cluster and Azure Storage Account

set -e  # Exit on error

# Variables - Customize these values
RESOURCE_GROUP="rg-aks-storage-lab"
LOCATION="eastus"
AKS_CLUSTER_NAME="aks-storage-cluster"
STORAGE_ACCOUNT_NAME="aksstorage$(openssl rand -hex 4)"
NODE_COUNT=2
NODE_VM_SIZE="Standard_DS2_v2"
KUBERNETES_VERSION="1.28.0"

echo "============================================"
echo "AKS Storage Lab - Infrastructure Deployment"
echo "============================================"
echo ""
echo "Configuration:"
echo "  Resource Group: $RESOURCE_GROUP"
echo "  Location: $LOCATION"
echo "  AKS Cluster: $AKS_CLUSTER_NAME"
echo "  Storage Account: $STORAGE_ACCOUNT_NAME"
echo "  Node Count: $NODE_COUNT"
echo ""

# Check if Azure CLI is installed
if ! command -v az &> /dev/null; then
    echo "Error: Azure CLI is not installed. Please install it first."
    exit 1
fi

# Check if user is logged in
echo "Checking Azure login status..."
az account show &> /dev/null || {
    echo "Please login to Azure:"
    az login
}

echo ""
echo "Step 1: Creating Resource Group..."
az group create \
  --name "$RESOURCE_GROUP" \
  --location "$LOCATION" \
  --output table

echo ""
echo "Step 2: Creating Storage Account..."
az storage account create \
  --name "$STORAGE_ACCOUNT_NAME" \
  --resource-group "$RESOURCE_GROUP" \
  --location "$LOCATION" \
  --sku Standard_LRS \
  --kind StorageV2 \
  --access-tier Hot \
  --allow-blob-public-access false \
  --min-tls-version TLS1_2 \
  --https-only true \
  --output table

echo ""
echo "Step 3: Creating blob container..."
az storage container create \
  --name data \
  --account-name "$STORAGE_ACCOUNT_NAME" \
  --auth-mode login \
  --output table

echo ""
echo "Step 4: Creating AKS Cluster (this will take 5-10 minutes)..."
az aks create \
  --resource-group "$RESOURCE_GROUP" \
  --name "$AKS_CLUSTER_NAME" \
  --location "$LOCATION" \
  --node-count "$NODE_COUNT" \
  --node-vm-size "$NODE_VM_SIZE" \
  --kubernetes-version "$KUBERNETES_VERSION" \
  --enable-managed-identity \
  --enable-workload-identity \
  --enable-oidc-issuer \
  --network-plugin azure \
  --network-policy azure \
  --generate-ssh-keys \
  --output table

echo ""
echo "Step 5: Getting AKS credentials..."
az aks get-credentials \
  --resource-group "$RESOURCE_GROUP" \
  --name "$AKS_CLUSTER_NAME" \
  --overwrite-existing

echo ""
echo "Step 6: Verifying deployment..."
kubectl get nodes

echo ""
echo "============================================"
echo "Deployment Complete!"
echo "============================================"
echo ""
echo "Save these values for the next labs:"
echo ""
echo "Resource Group: $RESOURCE_GROUP"
echo "Storage Account: $STORAGE_ACCOUNT_NAME"
echo "AKS Cluster: $AKS_CLUSTER_NAME"
echo ""

# Get OIDC Issuer URL
OIDC_ISSUER=$(az aks show -n "$AKS_CLUSTER_NAME" -g "$RESOURCE_GROUP" --query 'oidcIssuerProfile.issuerUrl' -o tsv)
echo "OIDC Issuer URL: $OIDC_ISSUER"
echo ""

# Get Kubelet Identity
KUBELET_IDENTITY=$(az aks show -n "$AKS_CLUSTER_NAME" -g "$RESOURCE_GROUP" --query 'identityProfile.kubeletidentity.clientId' -o tsv)
echo "Kubelet Identity Client ID: $KUBELET_IDENTITY"
echo ""

echo "Next step: Proceed to Lab 2 to configure managed identity"
echo ""
