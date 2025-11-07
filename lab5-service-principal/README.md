# Lab 5: Service Principal with Federated Credentials

In this lab, you will configure an Azure service principal with federated credentials to enable AKS pods to securely access Azure Storage without managing secrets or passwords. This is an alternative approach to the user-assigned managed identity used in Lab 2.

## Overview

This lab demonstrates a **secretless authentication** approach using:
- **Service Principal** (Azure AD application) instead of a user-assigned managed identity
- **Federated Identity Credentials** for OIDC-based authentication
- **AKS Workload Identity** for seamless integration with Kubernetes

For a detailed comparison between service principals and managed identities, see the [Authentication Methods Comparison](../AUTHENTICATION-COMPARISON.md) guide.

### Key Differences: Service Principal vs Managed Identity

| Aspect | Lab 2 (Managed Identity) | Lab 5 (Service Principal) |
|--------|--------------------------|---------------------------|
| **Identity Type** | User-Assigned Managed Identity | Service Principal (App Registration) |
| **Management** | Managed by Azure | Managed through Azure AD |
| **Use Case** | Simpler for Azure-only scenarios | Cross-platform, multi-cloud, or when app registration is required |
| **Lifecycle** | Tied to Azure resources | Independent lifecycle |
| **Permissions** | Azure RBAC only | Azure RBAC + Microsoft Graph API permissions |
| **Authentication** | Automatic in Azure | Federated credentials (no secrets) |

Both approaches use **workload identity** and **federated credentials** for passwordless authentication in AKS.

## Prerequisites

- Completed [Lab 1: Deploy Azure Infrastructure](../lab1-deploy-infrastructure/)
- Azure CLI installed and configured
- kubectl configured with access to your AKS cluster
- Permissions to create service principals in Azure AD

## Architecture

```
Pod with Service Account
        ↓ (uses)
Kubernetes Service Account (sp-workload-identity-sa)
        ↓ (federated with)
Azure AD Service Principal
        ↓ (has RBAC role)
Azure Storage Account
```

## Step-by-Step Instructions

### Option 1: Automated Setup (Recommended)

Use the provided script to configure everything automatically:

```bash
bash lab5-service-principal/configure-service-principal.sh
```

The script will:
1. Create a service principal (or use existing)
2. Assign Storage Blob Data Contributor role
3. Create Kubernetes service account
4. Set up federated identity credentials
5. Verify the configuration

### Option 2: Manual Setup

If you prefer to understand each step, follow the manual instructions below.

#### 1. Set Variables (If doing manual steps)

```bash
export RESOURCE_GROUP="rg-aks-storage-lab-wus3"
export AKS_CLUSTER_NAME="aks-storage-cluster"
export STORAGE_ACCOUNT_NAME="<your-storage-account-name>"
export SERVICE_PRINCIPAL_NAME="sp-aks-storage-lab"
export SERVICE_ACCOUNT_NAMESPACE="lab5"
export SERVICE_ACCOUNT_NAME="lab5-sp-sa"
```

#### 2. Get AKS OIDC Issuer URL

```bash
export AKS_OIDC_ISSUER=$(az aks show \
  --name $AKS_CLUSTER_NAME \
  --resource-group $RESOURCE_GROUP \
  --query "oidcIssuerProfile.issuerUrl" \
  --output tsv)

echo "OIDC Issuer: $AKS_OIDC_ISSUER"
```

#### 3. Create Service Principal

```bash
# Create service principal without role assignment
az ad sp create-for-rbac \
  --name $SERVICE_PRINCIPAL_NAME \
  --skip-assignment \
  --output json > sp-output.json

export SP_APP_ID=$(cat sp-output.json | jq -r '.appId')
export SP_OBJECT_ID=$(az ad sp show --id $SP_APP_ID --query "id" -o tsv)

echo "Service Principal App ID: $SP_APP_ID"
echo "Service Principal Object ID: $SP_OBJECT_ID"
```

**Important:** Save the output but do NOT save the password/secret. We won't use it with federated credentials.

#### 4. Assign Storage Blob Data Contributor Role

Get the storage account ID:

```bash
export STORAGE_ACCOUNT_ID=$(az storage account show \
  --name $STORAGE_ACCOUNT_NAME \
  --resource-group $RESOURCE_GROUP \
  --query 'id' \
  --output tsv)
```

Assign the role to the service principal:

```bash
az role assignment create \
  --role "Storage Blob Data Contributor" \
  --assignee $SP_APP_ID \
  --scope $STORAGE_ACCOUNT_ID
```

#### 5. Create Kubernetes Service Account

```bash
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: ServiceAccount
metadata:
  annotations:
    azure.workload.identity/client-id: $SP_APP_ID
  name: $SERVICE_ACCOUNT_NAME
  namespace: $SERVICE_ACCOUNT_NAMESPACE
EOF
```

Verify:

```bash
kubectl get serviceaccount $SERVICE_ACCOUNT_NAME -n $SERVICE_ACCOUNT_NAMESPACE
```

#### 6. Create Federated Identity Credential

This is the key step that enables passwordless authentication:

```bash
az ad app federated-credential create \
  --id $SP_APP_ID \
  --parameters "{
    \"name\": \"aks-sp-federated-credential\",
    \"issuer\": \"$AKS_OIDC_ISSUER\",
    \"subject\": \"system:serviceaccount:${SERVICE_ACCOUNT_NAMESPACE}:${SERVICE_ACCOUNT_NAME}\",
    \"audiences\": [\"api://AzureADTokenExchange\"]
  }"
```

#### 7. Verify Configuration

Check federated credentials:

```bash
az ad app federated-credential list --id $SP_APP_ID --output table
```

Check role assignment:

```bash
az role assignment list \
  --assignee $SP_APP_ID \
  --scope $STORAGE_ACCOUNT_ID \
  --output table
```

## Deploy the Application

Once the service principal is configured, deploy the sample application:

```bash
bash lab5-service-principal/deploy-app.sh
```

This will:
1. Deploy a Python Flask application that uses the service principal
2. Create a LoadBalancer service
3. Wait for the external IP assignment
4. Display test commands

## Test the Application

Get the external IP:

```bash
kubectl get service aks-storage-app-sp-service
```

Test the endpoints:

```bash
# Get external IP
EXTERNAL_IP=$(kubectl get service aks-storage-app-sp-service -o jsonpath='{.status.loadBalancer.ingress[0].ip}')

# Home page - shows auth method
curl http://$EXTERNAL_IP/

# Health check - verifies storage connectivity
curl http://$EXTERNAL_IP/health

# List blobs in container
curl http://$EXTERNAL_IP/list

# Upload a test file
curl http://$EXTERNAL_IP/upload
```

## Verify Workload Identity

Check that the Azure credentials are injected into pods:

```bash
POD=$(kubectl get pod -l app=aks-storage-app-sp -o jsonpath='{.items[0].metadata.name}')
kubectl exec $POD -- env | grep AZURE
```

You should see:
- `AZURE_CLIENT_ID` - Service principal app ID
- `AZURE_TENANT_ID` - Azure tenant ID
- `AZURE_FEDERATED_TOKEN_FILE` - Path to projected service account token

## View Logs

```bash
kubectl logs -l app=aks-storage-app-sp --tail=50 -f
```

## Understanding Federated Credentials

Federated credentials enable **passwordless authentication** by:

1. **Kubernetes** projects a signed OIDC token into the pod
2. **Azure AD** trusts tokens signed by the AKS OIDC issuer
3. **Service Principal** exchanges the Kubernetes token for an Azure token
4. **Application** uses the Azure token to access storage

This is more secure than:
- Storing secrets/passwords in Kubernetes
- Using connection strings
- Managing certificate rotation

## Comparison with Lab 2

Both Lab 2 (Managed Identity) and Lab 5 (Service Principal) achieve the same goal: secretless authentication to Azure Storage. Here's when to use each:

### Use Managed Identity (Lab 2) when:
- Your workload runs only on Azure
- You want simpler identity management
- You don't need Microsoft Graph API permissions
- You prefer Azure-managed lifecycle

### Use Service Principal (Lab 5) when:
- You need cross-platform authentication
- You require Microsoft Graph API permissions
- You're integrating with existing app registrations
- You need more granular control over identity lifecycle

## Troubleshooting

### Issue: Service principal role assignment fails

**Error:** "Principal does not exist in the directory"

**Solution:** Wait 30-60 seconds for the service principal to propagate in Azure AD, then retry:

```bash
sleep 60
az role assignment create \
  --role "Storage Blob Data Contributor" \
  --assignee $SP_APP_ID \
  --scope $STORAGE_ACCOUNT_ID
```

### Issue: Pods fail to authenticate

**Error:** "AADSTS700016: Application not found in the directory"

**Solution:** Verify the federated credential is correctly configured:

```bash
az ad app federated-credential list --id $SP_APP_ID --output table
```

Check that:
- `issuer` matches your AKS OIDC issuer URL
- `subject` matches `system:serviceaccount:default:sp-workload-identity-sa`
- `audiences` contains `api://AzureADTokenExchange`

### Issue: "FederatedCredentialNotFound" error

**Solution:** Wait a few minutes for the federated credential to propagate. The workload identity webhook needs time to recognize the new configuration.

### Issue: Storage access denied

**Solution:** Verify the role assignment:

```bash
az role assignment list \
  --assignee $SP_APP_ID \
  --all \
  --output table
```

Ensure "Storage Blob Data Contributor" role is assigned to the storage account scope.

## Security Best Practices

1. **No Secrets Required**: This approach eliminates the need for passwords or certificates
2. **Least Privilege**: Assign only the minimum required roles (Storage Blob Data Contributor)
3. **Scope Limitation**: Role assignments are scoped to specific storage accounts
4. **Audit Trail**: All authentication attempts are logged in Azure AD
5. **Token Lifetime**: Tokens are short-lived and automatically rotated

## Clean Up

### Remove Application Only

```bash
kubectl delete -f lab5-service-principal/k8s/deployment.yaml
kubectl delete -f lab5-service-principal/k8s/service.yaml
```

### Remove Service Principal Configuration

```bash
# Delete federated credential
az ad app federated-credential delete \
  --id $SP_APP_ID \
  --federated-credential-id aks-sp-federated-credential

# Delete role assignment
az role assignment delete \
  --assignee $SP_APP_ID \
  --scope $STORAGE_ACCOUNT_ID

# Delete service principal
az ad sp delete --id $SP_APP_ID

# Delete Kubernetes service account
kubectl delete serviceaccount $SERVICE_ACCOUNT_NAME -n $SERVICE_ACCOUNT_NAMESPACE
```

### Full Cleanup

Use the repository cleanup script which handles all labs:

```bash
bash cleanup.sh
```

## Advanced Scenarios

### Using Service Principal in Multiple Namespaces

Create service accounts in different namespaces pointing to the same service principal:

```bash
for ns in dev staging prod; do
  kubectl create namespace $ns --dry-run=client -o yaml | kubectl apply -f -
  
  cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: ServiceAccount
metadata:
  annotations:
    azure.workload.identity/client-id: $SP_APP_ID
  name: sp-workload-identity-sa
  namespace: $ns
EOF

  # Create federated credential for each namespace
  az ad app federated-credential create \
    --id $SP_APP_ID \
    --parameters "{
      \"name\": \"aks-sp-fed-cred-$ns\",
      \"issuer\": \"$AKS_OIDC_ISSUER\",
      \"subject\": \"system:serviceaccount:$ns:sp-workload-identity-sa\",
      \"audiences\": [\"api://AzureADTokenExchange\"]
    }"
done
```

### Adding Microsoft Graph Permissions

Service principals can be granted Microsoft Graph API permissions:

```bash
# Example: Grant User.Read.All permission
az ad app permission add \
  --id $SP_APP_ID \
  --api 00000003-0000-0000-c000-000000000000 \
  --api-permissions e1fe6dd8-ba31-4d61-89e7-88639da4683d=Role

# Grant admin consent
az ad app permission admin-consent --id $SP_APP_ID
```

This is useful when your application needs to interact with Microsoft Graph API in addition to Azure resources.

## Next Steps

- Compare the behavior between Lab 2 (Managed Identity) and Lab 5 (Service Principal)
- Explore Lab 3 (Python app) or Lab 4 (Scala app) with service principal authentication
- Set up monitoring and alerts for authentication failures
- Implement network policies to restrict pod-to-pod communication

## References

- [Azure AD Workload Identity](https://azure.github.io/azure-workload-identity/)
- [Service Principals in Azure](https://docs.microsoft.com/en-us/azure/active-directory/develop/app-objects-and-service-principals)
- [Federated Identity Credentials](https://docs.microsoft.com/en-us/graph/api/resources/federatedidentitycredentials-overview)
- [AKS Workload Identity Overview](https://docs.microsoft.com/en-us/azure/aks/workload-identity-overview)
- [OpenID Connect (OIDC)](https://openid.net/connect/)
