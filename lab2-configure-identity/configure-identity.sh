#!/bin/bash

# AKS Storage Lab - Configure Managed Identity Script
# This script configures workload identity for AKS to access Azure Storage

set -e  # Exit on error



# Source outputs from Lab 1 (env file resides at repo root)
SCRIPT_DIR="$(cd -- "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
LAB1_ENV="$REPO_ROOT/lab-outputs.env"
if [ -f "$LAB1_ENV" ]; then
  set -a
  source "$LAB1_ENV"
  set +a
else
  echo "Error: $LAB1_ENV not found. Please run Lab 1 deployment first."
  exit 1
fi
# Additional variables for this lab
MANAGED_IDENTITY_NAME="id-aks-storage"
SERVICE_ACCOUNT_NAMESPACE="default"
SERVICE_ACCOUNT_NAME="workload-identity-sa"

echo "================================================="
echo "AKS Storage Lab - Managed Identity Configuration"
echo "================================================="
echo ""

# Check if storage account name is still placeholder
if [ "$STORAGE_ACCOUNT_NAME" == "<your-storage-account-name>" ]; then
    echo "Error: Please update STORAGE_ACCOUNT_NAME in this script"
    echo "You can find it by running:"
    echo "  az storage account list -g $RESOURCE_GROUP --query '[0].name' -o tsv"
    exit 1
fi

echo "Configuration:"
echo "  Resource Group: $RESOURCE_GROUP"
echo "  AKS Cluster: $AKS_CLUSTER_NAME"
echo "  Storage Account: $STORAGE_ACCOUNT_NAME"
echo "  Managed Identity: $MANAGED_IDENTITY_NAME"
echo "  Service Account: $SERVICE_ACCOUNT_NAMESPACE/$SERVICE_ACCOUNT_NAME"
echo ""

# Check if Azure CLI is installed
if ! command -v az &> /dev/null; then
    echo "Error: Azure CLI is not installed."
    exit 1
fi

# Check if kubectl is installed
if ! command -v kubectl &> /dev/null; then
    echo "Error: kubectl is not installed."
    exit 1
fi

echo "Step 1: Getting AKS OIDC Issuer URL..."
AKS_OIDC_ISSUER=$(az aks show \
  --name "$AKS_CLUSTER_NAME" \
  --resource-group "$RESOURCE_GROUP" \
  --query "oidcIssuerProfile.issuerUrl" \
  --output tsv)

if [ -z "$AKS_OIDC_ISSUER" ]; then
    echo "Error: Could not retrieve OIDC issuer URL. Is workload identity enabled?"
    exit 1
fi

echo "  OIDC Issuer: $AKS_OIDC_ISSUER"
echo ""

echo "Step 2: Creating User-Assigned Managed Identity..."
az identity create \
  --name "$MANAGED_IDENTITY_NAME" \
  --resource-group "$RESOURCE_GROUP" \
  --location "$LOCATION" \
  --output table

echo ""
echo "Step 3: Getting Managed Identity details..."
USER_ASSIGNED_CLIENT_ID=$(az identity show \
  --resource-group "$RESOURCE_GROUP" \
  --name "$MANAGED_IDENTITY_NAME" \
  --query 'clientId' \
  --output tsv)

echo "  Client ID: $USER_ASSIGNED_CLIENT_ID"
echo ""

echo "Step 4: Getting Storage Account ID..."
STORAGE_ACCOUNT_ID=$(az storage account show \
  --name "$STORAGE_ACCOUNT_NAME" \
  --resource-group "$RESOURCE_GROUP" \
  --query 'id' \
  --output tsv)

echo "  Storage Account ID: $STORAGE_ACCOUNT_ID"
echo ""

echo "Step 5: Assigning Storage Blob Data Contributor role..."

# Retry loop for role assignment (wait for service principal propagation)
MAX_RETRIES=10
SLEEP_SECONDS=10
for ((i=1; i<=MAX_RETRIES; i++)); do
  set +e
  az role assignment create \
    --role "Storage Blob Data Contributor" \
    --assignee "$USER_ASSIGNED_CLIENT_ID" \
    --scope "$STORAGE_ACCOUNT_ID" \
    --output table
  STATUS=$?
  set -e
  if [ $STATUS -eq 0 ]; then
    echo "Role assignment succeeded."
    break
  else
    echo "Role assignment failed (attempt $i/$MAX_RETRIES). Waiting $SLEEP_SECONDS seconds and retrying..."
    sleep $SLEEP_SECONDS
  fi
  if [ $i -eq $MAX_RETRIES ]; then
    echo "ERROR: Role assignment failed after $MAX_RETRIES attempts."
    exit 1
  fi
done

echo ""
echo "Step 6: Creating Kubernetes Service Account..."
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: ServiceAccount
metadata:
  annotations:
    azure.workload.identity/client-id: $USER_ASSIGNED_CLIENT_ID
  name: $SERVICE_ACCOUNT_NAME
  namespace: $SERVICE_ACCOUNT_NAMESPACE
EOF

echo ""
echo "Step 7: Creating Federated Identity Credential..."
az identity federated-credential create \
  --name "aks-federated-credential" \
  --identity-name "$MANAGED_IDENTITY_NAME" \
  --resource-group "$RESOURCE_GROUP" \
  --issuer "$AKS_OIDC_ISSUER" \
  --subject "system:serviceaccount:${SERVICE_ACCOUNT_NAMESPACE}:${SERVICE_ACCOUNT_NAME}" \
  --audience "api://AzureADTokenExchange" \
  --output table

echo ""
echo "Step 8: Verifying configuration..."
echo ""
echo "Federated Credentials:"
az identity federated-credential list \
  --identity-name "$MANAGED_IDENTITY_NAME" \
  --resource-group "$RESOURCE_GROUP" \
  --output table

echo ""
echo "Role Assignments:"
az role assignment list \
  --assignee "$USER_ASSIGNED_CLIENT_ID" \
  --scope "$STORAGE_ACCOUNT_ID" \
  --output table

echo ""
echo "Kubernetes Service Account:"
kubectl get serviceaccount "$SERVICE_ACCOUNT_NAME" -n "$SERVICE_ACCOUNT_NAMESPACE"

echo ""
echo "================================================="
echo "Configuration Complete!"
echo "================================================="
echo ""
echo "Important values for Lab 3:"
echo ""
echo "AZURE_STORAGE_ACCOUNT_NAME=$STORAGE_ACCOUNT_NAME"
echo "AZURE_CLIENT_ID=$USER_ASSIGNED_CLIENT_ID"
echo "SERVICE_ACCOUNT_NAME=$SERVICE_ACCOUNT_NAME"
echo ""

# Append Lab 2 outputs to the shared env file (repo root)
LAB_ENV="$LAB1_ENV"
{
  echo ""
  echo "# Lab 2 outputs - Managed Identity configuration"
  echo "AZURE_CLIENT_ID=$USER_ASSIGNED_CLIENT_ID"
  echo "SERVICE_ACCOUNT_NAME=$SERVICE_ACCOUNT_NAME"
  echo "SERVICE_ACCOUNT_NAMESPACE=$SERVICE_ACCOUNT_NAMESPACE"
  echo "MANAGED_IDENTITY_NAME=$MANAGED_IDENTITY_NAME"
} >> "$LAB_ENV"
echo "Lab 2 outputs appended to $LAB_ENV"
echo ""
echo ""

echo "Note: Workload identity may take a few minutes to fully propagate."
echo ""
echo "Next step: Proceed to Lab 3 to deploy the sample application"
echo ""
