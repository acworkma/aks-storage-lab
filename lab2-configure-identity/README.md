# Lab 2: Configure Managed Identity

In this lab, you will configure Azure managed identity to allow your AKS pods to securely access Azure Storage, Key Vault, and Container Registry without managing credentials.

## Prerequisites

- Completed [Lab 1: Deploy Azure Infrastructure](../lab1-deploy-infrastructure/)
- Azure CLI installed and configured
- kubectl configured with access to your AKS cluster

## Overview

You will:
1. Create a user-assigned managed identity
2. Assign RBAC roles to the identity for Storage, Key Vault, and ACR
3. Create Kubernetes namespaces for labs 3 and 4
4. Create a Kubernetes service account in each namespace linked to the managed identity
5. Create federated identity credentials for each namespace

> **Note**: Lab 5 uses an independent Service Principal authentication path and does not require Lab 2. You can run Lab 5 directly after Lab 1.

## Architecture

```
Pod with Service Account (in lab3 or lab4 namespace)
        ↓ (uses)
Kubernetes Service Account (workload-identity-sa)
        ↓ (federated with)
Azure Managed Identity (id-aks-storage)
        ↓ (has RBAC roles)
   ┌────────┼────────┐
   ↓        ↓        ↓
Storage  Key Vault   ACR
Account
```

## Step-by-Step Instructions

### 1. Set Variables

If running manually, set these variables. Note: if you use `./configure-identity.sh`, values are automatically loaded from `lab-outputs.env`:

```bash
# These come from Lab 1's lab-outputs.env
export RESOURCE_GROUP="rg-aks-storage-lab-wus3"
export AKS_CLUSTER_NAME="aks-storage-cluster"
export STORAGE_ACCOUNT_NAME="<from-lab-outputs.env>"
export KEY_VAULT_NAME="kv-aks-auth"
export ACR_NAME="acraksauthlab"

# Lab 2 specific
export MANAGED_IDENTITY_NAME="id-aks-storage"
export SERVICE_ACCOUNT_NAME="workload-identity-sa"

# Namespaces for labs using managed identity (Lab 5 is independent)
LAB_NAMESPACES=("lab3" "lab4")

# Location is derived from resource group
export LOCATION=$(az group show --name $RESOURCE_GROUP --query location -o tsv)
```

### 2. Get AKS OIDC Issuer URL

```bash
export AKS_OIDC_ISSUER=$(az aks show \
  --name $AKS_CLUSTER_NAME \
  --resource-group $RESOURCE_GROUP \
  --query "oidcIssuerProfile.issuerUrl" \
  --output tsv)

echo "OIDC Issuer: $AKS_OIDC_ISSUER"
```

### 3. Create User-Assigned Managed Identity

```bash
az identity create \
  --name $MANAGED_IDENTITY_NAME \
  --resource-group $RESOURCE_GROUP \
  --location $LOCATION
```

Get the identity details:

```bash
export USER_ASSIGNED_CLIENT_ID=$(az identity show \
  --resource-group $RESOURCE_GROUP \
  --name $MANAGED_IDENTITY_NAME \
  --query 'clientId' \
  --output tsv)

echo "Managed Identity Client ID: $USER_ASSIGNED_CLIENT_ID"
```

### 4. Assign RBAC Roles

Get the resource IDs:

```bash
export STORAGE_ACCOUNT_ID=$(az storage account show \
  --name $STORAGE_ACCOUNT_NAME \
  --resource-group $RESOURCE_GROUP \
  --query 'id' \
  --output tsv)

export KEY_VAULT_ID=$(az keyvault show \
  --name $KEY_VAULT_NAME \
  --resource-group $RESOURCE_GROUP \
  --query 'id' \
  --output tsv)

export ACR_ID=$(az acr show \
  --name $ACR_NAME \
  --resource-group $RESOURCE_GROUP \
  --query 'id' \
  --output tsv)
```

Assign the roles:

```bash
# Storage Blob Data Contributor - read/write blobs
az role assignment create \
  --role "Storage Blob Data Contributor" \
  --assignee $USER_ASSIGNED_CLIENT_ID \
  --scope $STORAGE_ACCOUNT_ID

# Key Vault Secrets User - read secrets
az role assignment create \
  --role "Key Vault Secrets User" \
  --assignee $USER_ASSIGNED_CLIENT_ID \
  --scope $KEY_VAULT_ID

# AcrPush - push/pull container images
az role assignment create \
  --role "AcrPush" \
  --assignee $USER_ASSIGNED_CLIENT_ID \
  --scope $ACR_ID
```

### 5. Create Kubernetes Namespaces and Service Accounts

Create namespaces and service accounts for all labs:

```bash
for NS in "${LAB_NAMESPACES[@]}"; do
  # Create namespace
  kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f -

  # Create service account with workload identity annotation
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
```

Verify the service accounts were created:

```bash
for NS in "${LAB_NAMESPACES[@]}"; do
  kubectl get serviceaccount $SERVICE_ACCOUNT_NAME -n $NS
done
```

### 6. Create Federated Identity Credentials

Create a federated credential for each namespace:

```bash
for NS in "${LAB_NAMESPACES[@]}"; do
  az identity federated-credential create \
    --name "aks-federated-credential-$NS" \
    --identity-name $MANAGED_IDENTITY_NAME \
    --resource-group $RESOURCE_GROUP \
    --issuer $AKS_OIDC_ISSUER \
    --subject system:serviceaccount:${NS}:${SERVICE_ACCOUNT_NAME} \
    --audience api://AzureADTokenExchange
done
```

### 7. Verify Configuration

Check the federated credential:

```bash
az identity federated-credential list \
  --identity-name $MANAGED_IDENTITY_NAME \
  --resource-group $RESOURCE_GROUP \
  --output table
```

Check the role assignment:

```bash
az role assignment list \
  --assignee $USER_ASSIGNED_CLIENT_ID \
  --scope $STORAGE_ACCOUNT_ID \
  --output table
```

## Alternative: Deploy Using Script

You can use the provided script to automate all the steps:

```bash
./configure-identity.sh
```

The script automatically loads configuration from `lab-outputs.env` (created by Lab 1). No manual editing required.

## What You've Configured

After completing this lab:

1. **User-Assigned Managed Identity**
   - Name: `id-aks-storage`
   - Has federated credentials linked to your Kubernetes service accounts

2. **RBAC Role Assignments**
   - **Storage Blob Data Contributor** on Storage Account - can read, write, and delete blobs
   - **Key Vault Secrets User** on Key Vault - can read secrets
   - **AcrPush** on Container Registry - can push and pull images

3. **Kubernetes Namespaces and Service Accounts**
   - Namespaces: `lab3`, `lab4`, `lab5`
   - Service Account: `workload-identity-sa` in each namespace
   - Annotated with the managed identity client ID
   - Can be used by pods to acquire Azure tokens

4. **Federated Identity Credentials**
   - One credential per namespace: `aks-federated-credential-lab3`, `aks-federated-credential-lab4`, `aks-federated-credential-lab5`
   - Links Kubernetes service accounts to Azure managed identity
   - Enables workload identity federation

## Testing the Configuration

You can test the configuration with a simple pod in the lab3 namespace:

```bash
kubectl run test-pod -n lab3 \
  --image=mcr.microsoft.com/azure-cli:latest \
  --overrides='{"spec":{"serviceAccountName":"workload-identity-sa"}}' \
  --labels="azure.workload.identity/use=true" \
  --command -- sleep 3600
```

Wait for the pod to be ready:

```bash
kubectl wait --for=condition=ready pod/test-pod -n lab3 --timeout=60s
```

Test access to storage:

```bash
kubectl exec -n lab3 test-pod -- az storage blob list \
  --account-name $STORAGE_ACCOUNT_NAME \
  --container-name data \
  --auth-mode login
```

If successful, you should see an empty list (no error). Clean up:

```bash
kubectl delete pod test-pod -n lab3
```

## Troubleshooting

**Issue:** "FederatedIdentityCredentialNotReady" error
- **Solution:** Wait a few minutes for the federated credential to propagate.

**Issue:** Authorization failed when accessing storage
- **Solution:** Verify the role assignment and ensure the managed identity has the correct permissions.

**Issue:** Pod cannot acquire token
- **Solution:** Verify the service account annotation and federated credential configuration.

## Important Notes

- The workload identity takes a few minutes to fully propagate
- Pods must use the configured service account to access Azure resources
- The managed identity has access to Storage, Key Vault, and ACR in the resource group
- The script is idempotent - safe to run multiple times

## Next Steps

Proceed to [Lab 3: Deploy Sample Application](../lab3-sample-app/) to deploy a Python application that uses this configuration.

Each lab uses its own namespace:
- **Lab 3** (Python app): `lab3` namespace
- **Lab 4** (Scala app): `lab4` namespace

> **Note**: Lab 5 (Service Principal) is an independent path that doesn't require Lab 2. You can run Lab 5 directly after Lab 1.

## Clean Up

To remove the managed identity configuration (keep this if continuing to Labs 3-4):

```bash
# Delete federated credentials
for NS in "${LAB_NAMESPACES[@]}"; do
  az identity federated-credential delete \
    --name "aks-federated-credential-$NS" \
    --identity-name $MANAGED_IDENTITY_NAME \
    --resource-group $RESOURCE_GROUP
done

# Delete role assignments
az role assignment delete \
  --assignee $USER_ASSIGNED_CLIENT_ID \
  --scope $STORAGE_ACCOUNT_ID

# Delete managed identity
az identity delete \
  --name $MANAGED_IDENTITY_NAME \
  --resource-group $RESOURCE_GROUP

# Delete Kubernetes namespaces (this also deletes service accounts)
for NS in "${LAB_NAMESPACES[@]}"; do
  kubectl delete namespace $NS
done
```