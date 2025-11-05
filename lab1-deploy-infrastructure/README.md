# Lab 1: Deploy Azure Infrastructure

In this lab, you will deploy the necessary Azure infrastructure including an AKS cluster and Azure Storage Account.

## Prerequisites

- Azure CLI installed and configured
- An active Azure subscription
- Sufficient permissions to create resources in Azure

## Architecture

You will deploy:
- Resource Group
- Azure Kubernetes Service (AKS) cluster with workload identity enabled
- Azure Storage Account
- Virtual Network (VNet) for AKS

## Step-by-Step Instructions

### 1. Login to Azure

```bash
az login
```

Set your subscription (if you have multiple):
```bash
az account set --subscription <subscription-id>
```

### 2. Set Variables

Create a variables file or export environment variables:

```bash
# Set your preferred values
export RESOURCE_GROUP="rg-aks-storage-lab-wus3"
export LOCATION="westus3"
export AKS_CLUSTER_NAME="aks-storage-cluster"
export STORAGE_ACCOUNT_NAME="aksstorage$(openssl rand -hex 4)"
export NODE_COUNT=2
```


**Note:** The storage account name must be globally unique, lowercase, and contain only alphanumeric characters.

### 3. Create Resource Group

```bash
az group create \
  --name $RESOURCE_GROUP \
  --location $LOCATION
```

### 4. Deploy Using Bicep Template

We'll use Azure Bicep for infrastructure as code. Deploy the resources:

```bash
az deployment group create \
  --resource-group $RESOURCE_GROUP \
  --template-file deploy.bicep \
  --parameters aksClusterName=$AKS_CLUSTER_NAME \
  --parameters storageAccountName=$STORAGE_ACCOUNT_NAME \
  --parameters location=$LOCATION \
  --parameters nodeCount=$NODE_COUNT
```

This deployment will take approximately 5-10 minutes.

### 5. Verify Deployment

Check that the AKS cluster was created:

```bash
az aks list --resource-group $RESOURCE_GROUP --output table
```

Check that the storage account was created:

```bash
az storage account list --resource-group $RESOURCE_GROUP --output table
```

### 6. Get AKS Credentials

Configure kubectl to connect to your AKS cluster:

```bash
az aks get-credentials \
  --resource-group $RESOURCE_GROUP \
  --name $AKS_CLUSTER_NAME \
  --overwrite-existing
```

### 7. Verify Cluster Access

```bash
kubectl get nodes
```

You should see 2 nodes in Ready state.

```bash
kubectl get namespaces
```

## Alternative: Deploy Using Azure CLI Only

If you prefer not to use Bicep, you can deploy using the provided bash script:

```bash
./deploy.sh
```

Make sure to edit the script variables at the top before running.

## What's Deployed

After completing this lab, you will have:

1. **AKS Cluster**
   - 2 nodes (can be customized)
   - Workload identity enabled (for Lab 2)
   - OIDC issuer enabled
   - System-assigned managed identity

2. **Storage Account**
   - Standard_LRS replication
   - Blob storage enabled
   - Hot access tier

3. **Resource Group**
   - Contains all resources
   - Located in your specified region

## Outputs to Save

Save these values for the next labs:

```bash
# Get and save the storage account name
echo "Storage Account: $(az storage account list -g $RESOURCE_GROUP --query '[0].name' -o tsv)"

# Get and save the OIDC issuer URL (needed for Lab 2)
echo "OIDC Issuer: $(az aks show -n $AKS_CLUSTER_NAME -g $RESOURCE_GROUP --query 'oidcIssuerProfile.issuerUrl' -o tsv)"

# Get the AKS managed identity client ID (needed for Lab 2)
echo "Kubelet Identity: $(az aks show -n $AKS_CLUSTER_NAME -g $RESOURCE_GROUP --query 'identityProfile.kubeletidentity.clientId' -o tsv)"
```

## Troubleshooting

**Issue:** Storage account name already exists
- **Solution:** The storage account name must be globally unique. Generate a new name with a random suffix.

**Issue:** AKS deployment fails with quota exceeded
- **Solution:** Check your subscription quotas or try a different region.

**Issue:** Access denied errors
- **Solution:** Ensure you have Contributor or Owner role on the subscription/resource group.

## Next Steps

Proceed to [Lab 2: Configure Managed Identity](../lab2-configure-identity/) to set up secure access between AKS and Storage.

## Clean Up

If you need to start over:

```bash
az group delete --name $RESOURCE_GROUP --yes --no-wait
```

**Warning:** This will delete all resources in the resource group.