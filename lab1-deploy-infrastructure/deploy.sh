#!/bin/bash

# AKS Storage Lab - Infrastructure Deployment Script
# This script deploys an AKS cluster and Azure Storage Account

set -e  # Exit on error

# Variables - Customize these values
RESOURCE_GROUP="rg-aks-storage-lab-wus3"
LOCATION="westus3"
AKS_CLUSTER_NAME="aks-storage-cluster"
STORAGE_ACCOUNT_NAME="aksstorage$(openssl rand -hex 4)"
KEY_VAULT_NAME="kv-aks-auth"
ACR_NAME="acraksauthlab"
NODE_COUNT=2
NODE_VM_SIZE="Standard_DS2_v2"
# Kubernetes version: auto-detect latest stable if not overridden
if [[ -z "${KUBERNETES_VERSION}" ]]; then
  KUBERNETES_VERSION=$(az aks get-versions -l "$LOCATION" --query "values[?isPreview==null].patchVersions | [].keys(@)[]" -o tsv | sort -V | tail -n1 || echo "1.33.3")
fi

echo "============================================"
echo "AKS Storage Lab - Infrastructure Deployment"
echo "============================================"
echo ""
echo "Configuration:"
echo "  Resource Group: $RESOURCE_GROUP"
echo "  Location: $LOCATION"
echo "  AKS Cluster: $AKS_CLUSTER_NAME"
echo "  Storage Account: $STORAGE_ACCOUNT_NAME"
echo "  Key Vault: $KEY_VAULT_NAME"
echo "  Container Registry: $ACR_NAME"
echo "  Node Count: $NODE_COUNT"
echo "  Node VM Size: $NODE_VM_SIZE"
echo "  Kubernetes Version: $KUBERNETES_VERSION"
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
echo "Step 4: Creating Key Vault..."
az keyvault create \
  --name "$KEY_VAULT_NAME" \
  --resource-group "$RESOURCE_GROUP" \
  --location "$LOCATION" \
  --sku standard \
  --enable-rbac-authorization true \
  --output table

echo ""
echo "Step 5: Creating Azure Container Registry..."
az acr create \
  --name "$ACR_NAME" \
  --resource-group "$RESOURCE_GROUP" \
  --location "$LOCATION" \
  --sku Basic \
  --admin-enabled false \
  --output table

echo ""
echo "Step 6: Creating AKS Cluster (this will take 5-10 minutes)..."
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
  --attach-acr "$ACR_NAME" \
  --no-ssh-key \
  --output table

echo ""
echo "Step 7: Getting AKS credentials..."
az aks get-credentials \
  --resource-group "$RESOURCE_GROUP" \
  --name "$AKS_CLUSTER_NAME" \
  --overwrite-existing

echo ""
echo "Step 8: Verifying deployment..."
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
echo "Key Vault: $KEY_VAULT_NAME"
echo "Container Registry: $ACR_NAME"
echo ""

# Get OIDC Issuer URL
OIDC_ISSUER=$(az aks show -n "$AKS_CLUSTER_NAME" -g "$RESOURCE_GROUP" --query 'oidcIssuerProfile.issuerUrl' -o tsv)
echo "OIDC Issuer URL: $OIDC_ISSUER"
echo ""

# Get Kubelet Identity
KUBELET_IDENTITY=$(az aks show -n "$AKS_CLUSTER_NAME" -g "$RESOURCE_GROUP" --query 'identityProfile.kubeletidentity.clientId' -o tsv)
echo "Kubelet Identity Client ID: $KUBELET_IDENTITY"
echo ""

# Get ACR Login Server
ACR_LOGIN_SERVER=$(az acr show -n "$ACR_NAME" --query 'loginServer' -o tsv)
echo "ACR Login Server: $ACR_LOGIN_SERVER"
echo ""

# Get Key Vault URI
KEY_VAULT_URI=$(az keyvault show -n "$KEY_VAULT_NAME" --query 'properties.vaultUri' -o tsv)
echo "Key Vault URI: $KEY_VAULT_URI"
echo ""

# Determine repository root (one directory up from this script directory)
SCRIPT_DIR="$(cd -- "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# Always write the env file at the repo root so all labs have a stable path
OUTPUT_FILE="${OUTPUT_FILE:-$REPO_ROOT/lab-outputs.env}"

# Write outputs to env file for later labs (overwrites on Lab 1 rerun)
cat > "$OUTPUT_FILE" <<EOF
# Lab 1 outputs - Infrastructure deployment
RESOURCE_GROUP=$RESOURCE_GROUP
AKS_CLUSTER_NAME=$AKS_CLUSTER_NAME
STORAGE_ACCOUNT_NAME=$STORAGE_ACCOUNT_NAME
OIDC_ISSUER_URL=$OIDC_ISSUER
KUBELET_IDENTITY_CLIENT_ID=$KUBELET_IDENTITY
KEY_VAULT_NAME=$KEY_VAULT_NAME
KEY_VAULT_URI=$KEY_VAULT_URI
ACR_NAME=$ACR_NAME
ACR_LOGIN_SERVER=$ACR_LOGIN_SERVER
EOF
echo "Outputs written to $OUTPUT_FILE"
echo "You can source it with: export $(grep -v '^#' $OUTPUT_FILE | xargs)"
echo ""

echo "Next step: Proceed to Lab 2 to configure managed identity"
echo ""
