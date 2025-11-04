# Lab 2: Configure Managed Identity

In this lab, you will configure Azure managed identity to allow your AKS pods to securely access Azure Storage without managing credentials.

## Prerequisites

- Completed [Lab 1: Deploy Azure Infrastructure](../lab1-deploy-infrastructure/)
- Azure CLI installed and configured
- kubectl configured with access to your AKS cluster

## Overview

You will:
1. Create a user-assigned managed identity
2. Assign the Storage Blob Data Contributor role to the identity
3. Create a federated identity credential for workload identity
4. Create a Kubernetes service account linked to the managed identity

## Architecture

```
Pod with Service Account
        ↓ (uses)
Kubernetes Service Account
        ↓ (federated with)
Azure Managed Identity
        ↓ (has RBAC role)
Azure Storage Account
```

## Step-by-Step Instructions

### 1. Set Variables

Set the variables from Lab 1 (adjust if you used different values):

```bash
export RESOURCE_GROUP="rg-aks-storage-lab"
export LOCATION="eastus"
export AKS_CLUSTER_NAME="aks-storage-cluster"
export STORAGE_ACCOUNT_NAME="<your-storage-account-name>"
export MANAGED_IDENTITY_NAME="id-aks-storage"
export SERVICE_ACCOUNT_NAMESPACE="default"
export SERVICE_ACCOUNT_NAME="workload-identity-sa"
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

### 4. Assign Storage Blob Data Contributor Role

Get the storage account ID:

```bash
export STORAGE_ACCOUNT_ID=$(az storage account show \
  --name $STORAGE_ACCOUNT_NAME \
  --resource-group $RESOURCE_GROUP \
  --query 'id' \
  --output tsv)
```

Assign the role:

```bash
az role assignment create \
  --role "Storage Blob Data Contributor" \
  --assignee $USER_ASSIGNED_CLIENT_ID \
  --scope $STORAGE_ACCOUNT_ID
```

### 5. Create Kubernetes Service Account

Create the service account with workload identity annotation:

```bash
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: ServiceAccount
metadata:
  annotations:
    azure.workload.identity/client-id: $USER_ASSIGNED_CLIENT_ID
  name: $SERVICE_ACCOUNT_NAME
  namespace: $SERVICE_ACCOUNT_NAMESPACE
EOF
```

Verify the service account was created:

```bash
kubectl get serviceaccount $SERVICE_ACCOUNT_NAME -n $SERVICE_ACCOUNT_NAMESPACE
```

### 6. Create Federated Identity Credential

This links the Kubernetes service account to the Azure managed identity:

```bash
az identity federated-credential create \
  --name "aks-federated-credential" \
  --identity-name $MANAGED_IDENTITY_NAME \
  --resource-group $RESOURCE_GROUP \
  --issuer $AKS_OIDC_ISSUER \
  --subject system:serviceaccount:${SERVICE_ACCOUNT_NAMESPACE}:${SERVICE_ACCOUNT_NAME} \
  --audience api://AzureADTokenExchange
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

Make sure to edit the script variables at the top before running.

## What You've Configured

After completing this lab:

1. **User-Assigned Managed Identity**
   - Exists in your resource group
   - Has federated credentials linked to your Kubernetes service account

2. **RBAC Role Assignment**
   - Managed identity has "Storage Blob Data Contributor" role on the storage account
   - Can read, write, and delete blobs

3. **Kubernetes Service Account**
   - Annotated with the managed identity client ID
   - Can be used by pods to acquire Azure tokens

4. **Federated Identity Credential**
   - Links Kubernetes service account to Azure managed identity
   - Enables workload identity federation

## Testing the Configuration

You can test the configuration with a simple pod:

```bash
kubectl run test-pod \
  --image=mcr.microsoft.com/azure-cli:latest \
  --serviceaccount=$SERVICE_ACCOUNT_NAME \
  --command -- sleep 3600
```

Wait for the pod to be ready:

```bash
kubectl wait --for=condition=ready pod/test-pod --timeout=60s
```

Test access to storage:

```bash
kubectl exec test-pod -- az storage blob list \
  --account-name $STORAGE_ACCOUNT_NAME \
  --container-name data \
  --auth-mode login
```

If successful, you should see an empty list (no error). Clean up:

```bash
kubectl delete pod test-pod
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
- Pods must use the configured service account to access storage
- The managed identity only has access to the specific storage account

## Next Steps

Proceed to [Lab 3: Deploy Sample Application](../lab3-sample-app/) to deploy a Python application that uses this configuration.

## Clean Up

To remove the managed identity configuration (keep this if continuing to Lab 3):

```bash
# Delete federated credential
az identity federated-credential delete \
  --name "aks-federated-credential" \
  --identity-name $MANAGED_IDENTITY_NAME \
  --resource-group $RESOURCE_GROUP

# Delete role assignment
az role assignment delete \
  --assignee $USER_ASSIGNED_CLIENT_ID \
  --scope $STORAGE_ACCOUNT_ID

# Delete managed identity
az identity delete \
  --name $MANAGED_IDENTITY_NAME \
  --resource-group $RESOURCE_GROUP

# Delete Kubernetes service account
kubectl delete serviceaccount $SERVICE_ACCOUNT_NAME -n $SERVICE_ACCOUNT_NAMESPACE
```