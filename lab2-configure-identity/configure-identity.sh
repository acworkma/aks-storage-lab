#!/bin/bash

# AKS Storage Lab - Configure Managed Identity Script
# This script configures workload identity for AKS to access Azure Storage, Key Vault, and Container Registry

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
SERVICE_ACCOUNT_NAME="workload-identity-sa"

# Namespaces for all labs that need workload identity
LAB_NAMESPACES=("lab3" "lab4" "lab5")

# Get location from resource group (Lab 1 env doesn't export LOCATION)
LOCATION=$(az group show --name "$RESOURCE_GROUP" --query location -o tsv)

echo "================================================="
echo "AKS Storage Lab - Managed Identity Configuration"
echo "================================================="
echo ""

# Validate required variables from Lab 1
for var in STORAGE_ACCOUNT_NAME KEY_VAULT_NAME ACR_NAME; do
  if [ -z "${!var}" ]; then
    echo "Error: $var not found in lab-outputs.env."
    echo "Please ensure Lab 1 completed successfully with the latest deploy.sh"
    exit 1
  fi
done

echo "Configuration:"
echo "  Resource Group: $RESOURCE_GROUP"
echo "  Location: $LOCATION"
echo "  AKS Cluster: $AKS_CLUSTER_NAME"
echo "  Storage Account: $STORAGE_ACCOUNT_NAME"
echo "  Key Vault: $KEY_VAULT_NAME"
echo "  Container Registry: $ACR_NAME"
echo "  Managed Identity: $MANAGED_IDENTITY_NAME"
echo "  Service Account Name: $SERVICE_ACCOUNT_NAME"
echo "  Lab Namespaces: ${LAB_NAMESPACES[*]}"
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
if az identity show --name "$MANAGED_IDENTITY_NAME" --resource-group "$RESOURCE_GROUP" &>/dev/null; then
  echo "  Managed identity already exists. Skipping creation."
else
  az identity create \
    --name "$MANAGED_IDENTITY_NAME" \
    --resource-group "$RESOURCE_GROUP" \
    --location "$LOCATION" \
    --output table
fi

echo ""
echo "Step 3: Getting Managed Identity details..."
USER_ASSIGNED_CLIENT_ID=$(az identity show \
  --resource-group "$RESOURCE_GROUP" \
  --name "$MANAGED_IDENTITY_NAME" \
  --query 'clientId' \
  --output tsv)

echo "  Client ID: $USER_ASSIGNED_CLIENT_ID"
echo ""

echo "Step 4: Getting resource IDs..."
STORAGE_ACCOUNT_ID=$(az storage account show \
  --name "$STORAGE_ACCOUNT_NAME" \
  --resource-group "$RESOURCE_GROUP" \
  --query 'id' \
  --output tsv)
echo "  Storage Account ID: $STORAGE_ACCOUNT_ID"

KEY_VAULT_ID=$(az keyvault show \
  --name "$KEY_VAULT_NAME" \
  --resource-group "$RESOURCE_GROUP" \
  --query 'id' \
  --output tsv)
echo "  Key Vault ID: $KEY_VAULT_ID"

ACR_ID=$(az acr show \
  --name "$ACR_NAME" \
  --resource-group "$RESOURCE_GROUP" \
  --query 'id' \
  --output tsv)
echo "  ACR ID: $ACR_ID"
echo ""

# Helper function for idempotent role assignment
assign_role() {
  local role="$1"
  local assignee="$2"
  local scope="$3"
  local resource_name="$4"

  # Check if role assignment already exists
  EXISTING=$(az role assignment list --assignee "$assignee" --scope "$scope" --role "$role" --query "[].id" -o tsv)
  if [ -n "$EXISTING" ]; then
    echo "  Role '$role' already assigned on $resource_name. Skipping."
  else
    # Retry loop for role assignment (wait for service principal propagation)
    MAX_RETRIES=10
    SLEEP_SECONDS=10
    for ((i=1; i<=MAX_RETRIES; i++)); do
      set +e
      az role assignment create \
        --role "$role" \
        --assignee "$assignee" \
        --scope "$scope" \
        --output none
      STATUS=$?
      set -e
      if [ $STATUS -eq 0 ]; then
        echo "  Role '$role' assigned on $resource_name."
        break
      else
        echo "  Role assignment failed (attempt $i/$MAX_RETRIES). Waiting $SLEEP_SECONDS seconds..."
        sleep $SLEEP_SECONDS
      fi
      if [ $i -eq $MAX_RETRIES ]; then
        echo "ERROR: Role assignment failed after $MAX_RETRIES attempts."
        exit 1
      fi
    done
  fi
}

echo "Step 5: Assigning RBAC roles to Managed Identity..."
echo ""

echo "  5a: Storage Blob Data Contributor on Storage Account..."
assign_role "Storage Blob Data Contributor" "$USER_ASSIGNED_CLIENT_ID" "$STORAGE_ACCOUNT_ID" "Storage Account"

echo ""
echo "  5b: Key Vault Secrets User on Key Vault..."
assign_role "Key Vault Secrets User" "$USER_ASSIGNED_CLIENT_ID" "$KEY_VAULT_ID" "Key Vault"

echo ""
echo "  5c: AcrPush on Container Registry..."
assign_role "AcrPush" "$USER_ASSIGNED_CLIENT_ID" "$ACR_ID" "ACR"

echo ""
echo "Step 6: Creating Kubernetes namespaces and service accounts for all labs..."
for NS in "${LAB_NAMESPACES[@]}"; do
  echo ""
  echo "  Creating namespace: $NS"
  kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f -
  
  echo "  Creating service account: $SERVICE_ACCOUNT_NAME in $NS"
  cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: ServiceAccount
metadata:
  annotations:
    azure.workload.identity/client-id: $USER_ASSIGNED_CLIENT_ID
  name: $SERVICE_ACCOUNT_NAME
  namespace: $NS
EOF
done

echo ""
echo "Step 7: Creating Federated Identity Credentials for all namespaces..."
for NS in "${LAB_NAMESPACES[@]}"; do
  CRED_NAME="aks-federated-credential-$NS"
  echo ""
  echo "  Creating federated credential: $CRED_NAME"
  if az identity federated-credential show \
    --name "$CRED_NAME" \
    --identity-name "$MANAGED_IDENTITY_NAME" \
    --resource-group "$RESOURCE_GROUP" &>/dev/null; then
    echo "    Federated credential already exists. Skipping."
  else
    az identity federated-credential create \
      --name "$CRED_NAME" \
      --identity-name "$MANAGED_IDENTITY_NAME" \
      --resource-group "$RESOURCE_GROUP" \
      --issuer "$AKS_OIDC_ISSUER" \
      --subject "system:serviceaccount:${NS}:${SERVICE_ACCOUNT_NAME}" \
      --audience "api://AzureADTokenExchange" \
      --output table
  fi
done

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
  --all \
  --query "[].{Role:roleDefinitionName, Scope:scope}" \
  --output table

echo ""
echo "Kubernetes Service Accounts:"
for NS in "${LAB_NAMESPACES[@]}"; do
  echo "  Namespace: $NS"
  kubectl get serviceaccount "$SERVICE_ACCOUNT_NAME" -n "$NS" 2>/dev/null || echo "    Not found"
done

echo ""
echo "================================================="
echo "Configuration Complete!"
echo "================================================="
echo ""
echo "Important values for subsequent labs:"
echo ""
echo "AZURE_CLIENT_ID=$USER_ASSIGNED_CLIENT_ID"
echo "SERVICE_ACCOUNT_NAME=$SERVICE_ACCOUNT_NAME"
echo "MANAGED_IDENTITY_NAME=$MANAGED_IDENTITY_NAME"
echo "LAB_NAMESPACES=${LAB_NAMESPACES[*]}"
echo ""
echo "Roles assigned:"
echo "  - Storage Blob Data Contributor on $STORAGE_ACCOUNT_NAME"
echo "  - Key Vault Secrets User on $KEY_VAULT_NAME"
echo "  - AcrPush on $ACR_NAME"
echo ""

# Append Lab 2 outputs to the shared env file (repo root)
LAB_ENV="$LAB1_ENV"

# Check if Lab 2 outputs already exist in the file
if grep -q "# Lab 2 outputs" "$LAB_ENV"; then
  echo "Lab 2 outputs already exist in $LAB_ENV. Skipping append."
else
  {
    echo ""
    echo "# Lab 2 outputs - Managed Identity configuration"
    echo "AZURE_CLIENT_ID=$USER_ASSIGNED_CLIENT_ID"
    echo "SERVICE_ACCOUNT_NAME=$SERVICE_ACCOUNT_NAME"
    echo "MANAGED_IDENTITY_NAME=$MANAGED_IDENTITY_NAME"
  } >> "$LAB_ENV"
  echo "Lab 2 outputs appended to $LAB_ENV"
fi
echo ""

echo "Note: Workload identity may take a few minutes to fully propagate."
echo ""
echo "Next step: Proceed to Lab 3 to deploy the sample application"
echo "  - Lab 3 uses namespace: lab3"
echo "  - Lab 4 uses namespace: lab4"
echo "  - Lab 5 uses namespace: lab5"
echo ""
