#!/bin/bash

# Lab 5 - Configure Service Principal for AKS Workload Identity (Secretless)
# Creates or reuses an Azure AD application (service principal), adds a federated credential
# for the AKS OIDC issuer + service account subject, assigns Storage Blob Data Contributor
# on the storage account, creates the Kubernetes namespace & service account, and appends
# outputs to lab-outputs.env.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
LAB_ENV="$REPO_ROOT/lab-outputs.env"

if [[ -f "$LAB_ENV" ]]; then
  set -a
  source "$LAB_ENV"
  set +a
else
  echo "Error: $LAB_ENV not found. Run Lab 1 first." >&2
  exit 1
fi

SERVICE_PRINCIPAL_DISPLAY_NAME="${SERVICE_PRINCIPAL_DISPLAY_NAME:-sp-aks-storage-lab}"  # can override externally
SERVICE_ACCOUNT_NAMESPACE="${LAB5_NAMESPACE:-lab5}"  # dedicated namespace for lab 5
SERVICE_ACCOUNT_NAME="${LAB5_SERVICE_ACCOUNT_NAME:-lab5-sp-sa}"
FEDERATED_CREDENTIAL_NAME="aks-sp-federated-credential"
ROLE_NAME="Storage Blob Data Contributor"

echo "==============================================="
echo "Lab 5 - Service Principal Configuration"
echo "==============================================="
echo "Resource Group:        $RESOURCE_GROUP"
echo "AKS Cluster:           $AKS_CLUSTER_NAME"
echo "Storage Account:       $STORAGE_ACCOUNT_NAME"
echo "SP Display Name:       $SERVICE_PRINCIPAL_DISPLAY_NAME"
echo "K8s Namespace:         $SERVICE_ACCOUNT_NAMESPACE"
echo "K8s Service Account:   $SERVICE_ACCOUNT_NAME"
echo "Federated Credential:  $FEDERATED_CREDENTIAL_NAME"
echo "Role Assignment:       $ROLE_NAME"
echo "==============================================="

for bin in az kubectl; do
  if ! command -v "$bin" &>/dev/null; then
    echo "Error: $bin not installed" >&2
    exit 2
  fi
done

if [[ -z "${STORAGE_ACCOUNT_NAME:-}" ]]; then
  echo "Error: STORAGE_ACCOUNT_NAME not set in env file." >&2
  exit 3
fi

echo "Step 1: Retrieve AKS OIDC issuer URL..."
AKS_OIDC_ISSUER="${OIDC_ISSUER_URL:-}"  # Lab1 stored OIDC_ISSUER_URL
if [[ -z "$AKS_OIDC_ISSUER" ]]; then
  AKS_OIDC_ISSUER=$(az aks show -n "$AKS_CLUSTER_NAME" -g "$RESOURCE_GROUP" --query "oidcIssuerProfile.issuerUrl" -o tsv)
fi
if [[ -z "$AKS_OIDC_ISSUER" ]]; then
  echo "Error: Could not determine AKS OIDC Issuer URL." >&2
  exit 4
fi
echo "  OIDC Issuer: $AKS_OIDC_ISSUER"

echo "Step 2: Ensure Azure AD application exists..."
APP_ID=""; APP_OBJECT_ID=""
APP_JSON=$(az ad app list --display-name "$SERVICE_PRINCIPAL_DISPLAY_NAME" --query "[0]" -o json || true)
if [[ "$APP_JSON" != "" && "$APP_JSON" != "null" ]]; then
  APP_ID=$(echo "$APP_JSON" | jq -r '.appId')
  APP_OBJECT_ID=$(echo "$APP_JSON" | jq -r '.id')
  echo "  Reusing existing app: $APP_ID"
else
  echo "  Creating new Azure AD application..."
  CREATE_OUT=$(az ad app create --display-name "$SERVICE_PRINCIPAL_DISPLAY_NAME" -o json)
  APP_ID=$(echo "$CREATE_OUT" | jq -r '.appId')
  APP_OBJECT_ID=$(echo "$CREATE_OUT" | jq -r '.id')
  echo "  Created app: $APP_ID"
fi

echo "Step 3: Ensure service principal exists..."
if az ad sp show --id "$APP_ID" &>/dev/null; then
  echo "  Service principal already exists."
else
  echo "  Creating service principal (may take ~30s propagation)..."
  az ad sp create --id "$APP_ID" --output none
fi

echo "Step 4: Get Storage Account resource ID..."
STORAGE_ACCOUNT_ID=$(az storage account show -n "$STORAGE_ACCOUNT_NAME" -g "$RESOURCE_GROUP" --query id -o tsv)
echo "  Storage Account ID: $STORAGE_ACCOUNT_ID"

echo "Step 5: Assign $ROLE_NAME (retry for propagation)..."
if az role assignment list --assignee "$APP_ID" --scope "$STORAGE_ACCOUNT_ID" --query "[?roleDefinitionName=='$ROLE_NAME'] | length(@)" -o tsv | grep -q '^1$'; then
  echo "  Role assignment already exists. Skipping."
else
  MAX_RETRIES=10; SLEEP=10; ASSIGNED=0
  for ((i=1;i<=MAX_RETRIES;i++)); do
    set +e
    az role assignment create --role "$ROLE_NAME" --assignee "$APP_ID" --scope "$STORAGE_ACCOUNT_ID" --output none
    RC=$?
    set -e
    if [[ $RC -eq 0 ]]; then
      ASSIGNED=1; echo "  Role assignment succeeded."; break
    else
      echo "  Attempt $i failed, retrying in $SLEEP s..."
      sleep $SLEEP
    fi
  done
  if [[ $ASSIGNED -ne 1 ]]; then
    echo "ERROR: Role assignment failed after $MAX_RETRIES attempts." >&2
    exit 5
  fi
fi

echo "Step 6: Create namespace & service account..."
kubectl get namespace "$SERVICE_ACCOUNT_NAMESPACE" &>/dev/null || kubectl create namespace "$SERVICE_ACCOUNT_NAMESPACE"
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: ServiceAccount
metadata:
  name: $SERVICE_ACCOUNT_NAME
  namespace: $SERVICE_ACCOUNT_NAMESPACE
  annotations:
    azure.workload.identity/client-id: $APP_ID
EOF

echo "Step 7: Create or verify federated credential..."
FED_LIST=$(az ad app federated-credential list --id "$APP_ID" -o json || echo '[]')
if echo "$FED_LIST" | jq -e --arg NAME "$FEDERATED_CREDENTIAL_NAME" '.[] | select(.name==$NAME)' >/dev/null; then
  echo "  Federated credential already exists."
else
  FC_JSON=$(jq -n \
    --arg name "$FEDERATED_CREDENTIAL_NAME" \
    --arg issuer "$AKS_OIDC_ISSUER" \
    --arg subject "system:serviceaccount:$SERVICE_ACCOUNT_NAMESPACE:$SERVICE_ACCOUNT_NAME" \
    '{name:$name, issuer:$issuer, subject:$subject, audiences:["api://AzureADTokenExchange"]}')
  az ad app federated-credential create --id "$APP_ID" --parameters "$FC_JSON" --output none
  echo "  Federated credential created."
fi

echo "Step 8: Verification summary"
echo "  App ID:        $APP_ID"
echo "  Object ID:     $APP_OBJECT_ID"
echo "  K8s SA:        $SERVICE_ACCOUNT_NAMESPACE/$SERVICE_ACCOUNT_NAME"
echo "  OIDC Issuer:   $AKS_OIDC_ISSUER"
echo "  Role:          $ROLE_NAME on $STORAGE_ACCOUNT_NAME"

echo "Step 9: Append outputs to env file..."
{
  echo ""; echo "# Lab 5 outputs - Service Principal configuration";
  echo "LAB5_SERVICE_PRINCIPAL_APP_ID=$APP_ID";
  echo "LAB5_SERVICE_PRINCIPAL_OBJECT_ID=$APP_OBJECT_ID";
  echo "LAB5_SERVICE_ACCOUNT_NAME=$SERVICE_ACCOUNT_NAME";
  echo "LAB5_SERVICE_ACCOUNT_NAMESPACE=$SERVICE_ACCOUNT_NAMESPACE";
  echo "LAB5_FEDERATED_CREDENTIAL_NAME=$FEDERATED_CREDENTIAL_NAME";
  echo "LAB5_ROLE_NAME=$ROLE_NAME";
} >> "$LAB_ENV"
echo "  Outputs appended to $LAB_ENV"

echo "==============================================="
echo "Lab 5 configuration complete. Next: run deploy-app.sh"
echo "==============================================="
#!/bin/bash

echo "==============================================="
echo "Lab 5 configuration complete. Next: run deploy-app.sh"
echo "==============================================="
