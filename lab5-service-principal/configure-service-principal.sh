#!/bin/bash

# AKS Storage Lab - Configure Service Principal with Federated Credentials
# This script configures a service principal with federated credentials for AKS to access Azure Storage

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
SERVICE_PRINCIPAL_NAME="sp-aks-storage-lab"
SERVICE_ACCOUNT_NAMESPACE="default"
SERVICE_ACCOUNT_NAME="sp-workload-identity-sa"

echo "=========================================================="
echo "AKS Storage Lab - Service Principal Configuration"
echo "=========================================================="
echo ""

# Check if storage account name is still placeholder
if [ "$STORAGE_ACCOUNT_NAME" == "<your-storage-account-name>" ]; then
    echo "Error: Please update STORAGE_ACCOUNT_NAME in lab-outputs.env"
    echo "You can find it by running:"
    echo "  az storage account list -g $RESOURCE_GROUP --query '[0].name' -o tsv"
    exit 1
fi

echo "Configuration:"
echo "  Resource Group: $RESOURCE_GROUP"
echo "  AKS Cluster: $AKS_CLUSTER_NAME"
echo "  Storage Account: $STORAGE_ACCOUNT_NAME"
echo "  Service Principal: $SERVICE_PRINCIPAL_NAME"
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

echo "Step 2: Creating Service Principal..."
# Check if service principal already exists
SP_APP_ID=$(az ad sp list --display-name "$SERVICE_PRINCIPAL_NAME" --query "[0].appId" -o tsv)

if [ -z "$SP_APP_ID" ]; then
    echo "  Creating new service principal..."
    SP_OUTPUT=$(az ad sp create-for-rbac --name "$SERVICE_PRINCIPAL_NAME" --skip-assignment --output json)
    SP_APP_ID=$(echo "$SP_OUTPUT" | jq -r '.appId')
    SP_OBJECT_ID=$(az ad sp show --id "$SP_APP_ID" --query "id" -o tsv)
    echo "  Created service principal with App ID: $SP_APP_ID"
else
    echo "  Service principal already exists with App ID: $SP_APP_ID"
    SP_OBJECT_ID=$(az ad sp show --id "$SP_APP_ID" --query "id" -o tsv)
fi

echo "  App ID: $SP_APP_ID"
echo "  Object ID: $SP_OBJECT_ID"
echo ""

echo "Step 3: Getting Storage Account ID..."
STORAGE_ACCOUNT_ID=$(az storage account show \
  --name "$STORAGE_ACCOUNT_NAME" \
  --resource-group "$RESOURCE_GROUP" \
  --query 'id' \
  --output tsv)

echo "  Storage Account ID: $STORAGE_ACCOUNT_ID"
echo ""

echo "Step 4: Assigning Storage Blob Data Contributor role..."
# Retry loop for role assignment (wait for service principal propagation)
MAX_RETRIES=10
SLEEP_SECONDS=10
for ((i=1; i<=MAX_RETRIES; i++)); do
  set +e
  az role assignment create \
    --role "Storage Blob Data Contributor" \
    --assignee "$SP_APP_ID" \
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
echo "Step 5: Creating Kubernetes Service Account..."
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: ServiceAccount
metadata:
  annotations:
    azure.workload.identity/client-id: $SP_APP_ID
  name: $SERVICE_ACCOUNT_NAME
  namespace: $SERVICE_ACCOUNT_NAMESPACE
EOF

echo ""
echo "Step 6: Creating Federated Identity Credential..."
# Check if federated credential already exists
FED_CRED_NAME="aks-sp-federated-credential"
EXISTING_FED_CRED=$(az ad app federated-credential list --id "$SP_APP_ID" --query "[?name=='$FED_CRED_NAME'].name" -o tsv)

if [ -z "$EXISTING_FED_CRED" ]; then
    echo "  Creating new federated credential..."
    az ad app federated-credential create \
      --id "$SP_APP_ID" \
      --parameters "{
        \"name\": \"$FED_CRED_NAME\",
        \"issuer\": \"$AKS_OIDC_ISSUER\",
        \"subject\": \"system:serviceaccount:${SERVICE_ACCOUNT_NAMESPACE}:${SERVICE_ACCOUNT_NAME}\",
        \"audiences\": [\"api://AzureADTokenExchange\"]
      }" \
      --output table
else
    echo "  Federated credential '$FED_CRED_NAME' already exists. Skipping creation."
fi

echo ""
echo "Step 7: Verifying configuration..."
echo ""
echo "Federated Credentials:"
az ad app federated-credential list \
  --id "$SP_APP_ID" \
  --output table

echo ""
echo "Role Assignments:"
az role assignment list \
  --assignee "$SP_APP_ID" \
  --scope "$STORAGE_ACCOUNT_ID" \
  --output table

echo ""
echo "Kubernetes Service Account:"
kubectl get serviceaccount "$SERVICE_ACCOUNT_NAME" -n "$SERVICE_ACCOUNT_NAMESPACE"

echo ""
echo "=========================================================="
echo "Configuration Complete!"
echo "=========================================================="
echo ""
echo "Important values for Lab 5 application deployment:"
echo ""
echo "AZURE_STORAGE_ACCOUNT_NAME=$STORAGE_ACCOUNT_NAME"
echo "AZURE_CLIENT_ID=$SP_APP_ID"
echo "SERVICE_ACCOUNT_NAME=$SERVICE_ACCOUNT_NAME"
echo ""

# Append Lab 5 outputs to the shared env file (repo root)
LAB_ENV="$LAB1_ENV"

# Remove old Lab 5 outputs if they exist (more robust cleanup)
grep -v "^# Lab 5 outputs" "$LAB_ENV" | grep -v "^SP_APP_ID=" | grep -v "^SP_OBJECT_ID=" | grep -v "^SP_SERVICE_ACCOUNT_NAME=" | grep -v "^SP_SERVICE_ACCOUNT_NAMESPACE=" | grep -v "^SP_NAME=" > "$LAB_ENV.tmp" && mv "$LAB_ENV.tmp" "$LAB_ENV"

{
  echo ""
  echo "# Lab 5 outputs - Service Principal configuration"
  echo "SP_APP_ID=$SP_APP_ID"
  echo "SP_OBJECT_ID=$SP_OBJECT_ID"
  echo "SP_SERVICE_ACCOUNT_NAME=$SERVICE_ACCOUNT_NAME"
  echo "SP_SERVICE_ACCOUNT_NAMESPACE=$SERVICE_ACCOUNT_NAMESPACE"
  echo "SP_NAME=$SERVICE_PRINCIPAL_NAME"
} >> "$LAB_ENV"
echo "Lab 5 outputs appended to $LAB_ENV"
echo ""
echo ""

echo "Note: Workload identity with service principal may take a few minutes to fully propagate."
echo ""
echo "Next step: Deploy an application using the service principal authentication"
echo "  You can use: bash lab5-service-principal/deploy-app.sh"
echo ""
