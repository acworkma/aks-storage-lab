# Lab 3: Deploy Sample Application

In this lab, you will deploy a Python application that demonstrates secure access to Azure Storage using the managed identity configured in Lab 2.

## Prerequisites

- Completed [Lab 1: Deploy Azure Infrastructure](../lab1-deploy-infrastructure/)
- Completed [Lab 2: Configure Managed Identity](../lab2-configure-identity/)
- kubectl configured with access to your AKS cluster
- Docker installed (for building container images)

## Overview

The sample application:
- Uses Azure SDK for Python
- Authenticates to Azure Storage using workload identity (no credentials needed)
- Lists blobs in the storage container
- Uploads a test file to demonstrate write access
- Provides a simple web interface to view results
- Deploys to the `lab3` namespace (created by Lab 2)

## Architecture

```
Browser → Service (LoadBalancer)
              ↓
          Pod (Python App) [namespace: lab3]
              ↓ (uses service account)
          Workload Identity
              ↓ (authenticates)
          Azure Storage Account
```

## Application Files

The sample application consists of:
- `app/app.py` - Python Flask application
- `app/requirements.txt` - Python dependencies
- `app/Dockerfile` - Container image definition
- `k8s/deployment.yaml` - Kubernetes deployment manifest
- `k8s/service.yaml` - Kubernetes service manifest

## Quick Start

The easiest way to deploy is using the provided script:

```bash
./deploy-app.sh
```

This script will:
1. Build the Docker image from `app/Dockerfile`
2. Push the image to your Azure Container Registry
3. Deploy the application to the `lab3` namespace
4. Wait for the external IP to be assigned

## Step-by-Step Instructions

### 1. Review the Application Code

The application is located in the `app/` directory. Review the code to understand how it uses workload identity:

```bash
cat app/app.py
```

Key points:
- Uses `DefaultAzureCredential` for authentication
- No connection strings or keys in the code
- Relies on the Kubernetes service account for identity

### 2. Build and Push Container Image

```bash
# Source environment variables from previous labs
source ../lab-outputs.env

# Build the Docker image
docker build -t aks-storage-app-python:v1 app/

# Login to ACR
az acr login --name $ACR_NAME

# Tag and push to ACR
docker tag aks-storage-app-python:v1 $ACR_LOGIN_SERVER/aks-storage-app-python:v1
docker push $ACR_LOGIN_SERVER/aks-storage-app-python:v1
```

### 3. Deploy the Application

Apply the Kubernetes manifests (the deploy script handles variable substitution):

```bash
# Substitute storage account name and image, then apply
sed -e "s|image: aks-storage-app-python:latest|image: $ACR_LOGIN_SERVER/aks-storage-app-python:v1|g" \
    -e "s/<your-storage-account-name>/$STORAGE_ACCOUNT_NAME/g" \
    k8s/deployment.yaml | kubectl apply -f -

kubectl apply -f k8s/service.yaml
```

### 4. Verify Deployment

Check that the pod is running:

```bash
kubectl get pods -n lab3 -l app=aks-storage-app
```

Wait for the pod to be ready:

```bash
kubectl wait --for=condition=ready pod -l app=aks-storage-app -n lab3 --timeout=120s
```

Check the logs to ensure it started correctly:

```bash
kubectl logs -l app=aks-storage-app -n lab3 --tail=50
```

### 5. Access the Application

Get the external IP address:

```bash
kubectl get service aks-storage-app-service -n lab3
```

Wait for the `EXTERNAL-IP` to be assigned (this may take a few minutes).

Once you have the IP, access the application:

```bash
export EXTERNAL_IP=$(kubectl get service aks-storage-app-service -n lab3 -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
echo "Application URL: http://$EXTERNAL_IP"
```

Open the URL in your browser or use curl:

```bash
curl http://$EXTERNAL_IP
```

### 6. Test Storage Operations

The application provides several endpoints:

**List blobs:**
```bash
curl http://$EXTERNAL_IP/list
```

**Upload a test file:**
```bash
curl -X POST http://$EXTERNAL_IP/upload
```

**Health check:**
```bash
curl http://$EXTERNAL_IP/health
```

### 7. View Results in Azure Portal

1. Go to the Azure Portal
2. Navigate to your storage account
3. Click on "Containers" → "data"
4. You should see the test file uploaded by the application

## Application Details

### How It Works

1. **Pod starts** with the workload identity service account
2. **Azure SDK** uses `DefaultAzureCredential` to automatically discover the identity
3. **Token acquisition**: The SDK exchanges the Kubernetes service account token for an Azure AD token
4. **Storage access**: The application uses the token to access Azure Storage
5. **No secrets**: No connection strings or keys are stored in the code or configuration

### Security Benefits

- ✅ No credentials in code
- ✅ No secrets in environment variables
- ✅ Automatic token rotation
- ✅ Follows principle of least privilege
- ✅ Audit trail through Azure AD

## Troubleshooting

**Issue:** Pod fails to start with ImagePullBackOff
- **Solution:** Verify the image name and ensure you have access to the registry.

**Issue:** Application cannot authenticate to storage
- **Solution:** Verify the service account is correctly configured and the workload identity is properly set up.

**Issue:** "403 Forbidden" errors when accessing storage
- **Solution:** Verify the managed identity has the "Storage Blob Data Contributor" role.

**Issue:** External IP shows \<pending\> for a long time
- **Solution:** This is normal and can take 5-10 minutes in some regions.

## View Application Logs

To see detailed logs:

```bash
kubectl logs -l app=aks-storage-app -n lab3 -f
```

## Testing Different Scenarios

### Test 1: Verify Managed Identity

Check that the pod has the correct identity:

```bash
POD_NAME=$(kubectl get pod -n lab3 -l app=aks-storage-app -o jsonpath='{.items[0].metadata.name}')
kubectl exec -n lab3 $POD_NAME -- env | grep AZURE
```

### Test 2: Interactive Testing

Get a shell in the pod:

```bash
kubectl exec -n lab3 -it $POD_NAME -- /bin/bash
```

Inside the pod, you can run Python code to test storage access:

```python
python3 -c "
from azure.identity import DefaultAzureCredential
from azure.storage.blob import BlobServiceClient
import os

account_name = os.getenv('AZURE_STORAGE_ACCOUNT_NAME')
account_url = f'https://{account_name}.blob.core.windows.net'

credential = DefaultAzureCredential()
blob_service_client = BlobServiceClient(account_url, credential=credential)

container_client = blob_service_client.get_container_client('data')
blobs = list(container_client.list_blobs())
print(f'Found {len(blobs)} blobs')
"
```

## Clean Up

To remove the application:

```bash
kubectl delete -f k8s/deployment.yaml
kubectl delete -f k8s/service.yaml
```

Or delete the entire namespace:

```bash
kubectl delete namespace lab3
```

To clean up all lab resources:

```bash
az group delete --name $RESOURCE_GROUP --yes --no-wait
```

**Warning:** This will delete all resources including AKS, Storage, and Managed Identity.

## What You've Learned

After completing this lab, you've learned:

1. ✅ How to deploy applications to AKS
2. ✅ How to use workload identity for secure authentication
3. ✅ How to access Azure Storage without managing credentials
4. ✅ Best practices for cloud-native application security
5. ✅ How to troubleshoot identity and access issues

## Next Steps

- Explore other Azure services that support managed identities
- Learn about Azure Key Vault integration with AKS
- Implement monitoring and logging for your applications
- Explore Azure Policy for governance

## Additional Resources

- [Azure SDK for Python](https://docs.microsoft.com/en-us/azure/developer/python/)
- [DefaultAzureCredential](https://docs.microsoft.com/en-us/python/api/azure-identity/azure.identity.defaultazurecredential)
- [Azure Storage SDK for Python](https://docs.microsoft.com/en-us/azure/storage/blobs/storage-quickstart-blobs-python)
- [AKS Best Practices](https://docs.microsoft.com/en-us/azure/aks/best-practices)