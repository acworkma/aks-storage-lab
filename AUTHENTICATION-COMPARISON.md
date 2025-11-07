# Authentication Methods Comparison

This document compares the two authentication approaches available in this lab series:
- **Lab 2**: User-Assigned Managed Identity
- **Lab 5**: Service Principal with Federated Credentials

## Quick Decision Guide

### Use Managed Identity (Lab 2) if:
- ✅ Your workload runs only on Azure
- ✅ You want the simplest setup and management
- ✅ You prefer Azure to automatically manage the identity lifecycle
- ✅ You don't need Microsoft Graph API permissions
- ✅ You want Azure to handle identity updates and maintenance

### Use Service Principal (Lab 5) if:
- ✅ You need cross-platform authentication (Azure + on-premises/other clouds)
- ✅ You require Microsoft Graph API permissions or directory operations
- ✅ You're integrating with existing app registrations
- ✅ You need independent identity lifecycle management
- ✅ You have compliance requirements for app-based identities
- ✅ You need more granular control over identity configuration

## Detailed Comparison

| Feature | Managed Identity (Lab 2) | Service Principal (Lab 5) |
|---------|--------------------------|---------------------------|
| **Identity Type** | Azure Managed Identity | Azure AD Application + Service Principal |
| **Creation** | `az identity create` | `az ad sp create-for-rbac` |
| **Management** | Fully managed by Azure | Managed through Azure AD |
| **Secrets** | None required | None required (with federated credentials) |
| **Lifecycle** | Tied to Azure subscription | Independent of Azure resources |
| **RBAC Permissions** | ✅ Yes | ✅ Yes |
| **Microsoft Graph API** | ❌ No | ✅ Yes |
| **Cross-Platform Auth** | Azure only | Multi-cloud, on-premises |
| **Federated Credentials** | `az identity federated-credential` | `az ad app federated-credential` |
| **Service Account Annotation** | `azure.workload.identity/client-id: <identity-client-id>` | `azure.workload.identity/client-id: <sp-app-id>` |
| **Token Exchange** | OIDC → Azure Managed Identity token | OIDC → Azure AD token |
| **Setup Complexity** | ⭐⭐ Simple | ⭐⭐⭐ Moderate |
| **Maintenance** | ⭐⭐⭐⭐⭐ Minimal (auto-managed) | ⭐⭐⭐⭐ Low (manual updates) |
| **Use Outside Azure** | ❌ Not supported | ✅ Supported (with proper setup) |
| **App Registration** | Not required | Required |
| **Cleanup** | Delete identity | Delete app registration + SP |

## Authentication Flow

Both approaches use the same workload identity pattern but with different identity providers:

### Managed Identity Flow (Lab 2)
```
1. Pod requests token from Kubernetes
   ↓
2. Kubernetes projects OIDC token (via service account)
   ↓
3. Azure Workload Identity webhook intercepts token
   ↓
4. Token exchanged for Azure Managed Identity token
   ↓
5. Application uses token to access Azure Storage
```

### Service Principal Flow (Lab 5)
```
1. Pod requests token from Kubernetes
   ↓
2. Kubernetes projects OIDC token (via service account)
   ↓
3. Azure Workload Identity webhook intercepts token
   ↓
4. Token exchanged for Azure AD token (via service principal)
   ↓
5. Application uses token to access Azure Storage
```

The key difference is **which Azure identity receives the final token**.

## Configuration Commands

### Managed Identity (Lab 2)

```bash
# Create managed identity
az identity create --name id-aks-storage --resource-group $RESOURCE_GROUP

# Assign RBAC role
az role assignment create \
  --role "Storage Blob Data Contributor" \
  --assignee $MANAGED_IDENTITY_CLIENT_ID \
  --scope $STORAGE_ACCOUNT_ID

# Create federated credential
az identity federated-credential create \
  --name aks-federated-credential \
  --identity-name id-aks-storage \
  --resource-group $RESOURCE_GROUP \
  --issuer $AKS_OIDC_ISSUER \
  --subject "system:serviceaccount:default:workload-identity-sa" \
  --audience "api://AzureADTokenExchange"
```

### Service Principal (Lab 5)

```bash
# Create service principal
az ad sp create-for-rbac --name sp-aks-storage-lab --skip-assignment

# Assign RBAC role
az role assignment create \
  --role "Storage Blob Data Contributor" \
  --assignee $SP_APP_ID \
  --scope $STORAGE_ACCOUNT_ID

# Create federated credential
az ad app federated-credential create \
  --id $SP_APP_ID \
  --parameters '{
    "name": "aks-sp-federated-credential",
    "issuer": "'$AKS_OIDC_ISSUER'",
    "subject": "system:serviceaccount:default:sp-workload-identity-sa",
    "audiences": ["api://AzureADTokenExchange"]
  }'
```

## Security Considerations

### Both Approaches
- ✅ **Passwordless**: No secrets stored in Kubernetes
- ✅ **Short-lived tokens**: Tokens expire and rotate automatically
- ✅ **RBAC controlled**: Permissions managed via Azure RBAC
- ✅ **Audit trail**: All authentication logged in Azure AD
- ✅ **Principle of least privilege**: Scoped permissions

### Managed Identity Specific
- ✅ Simpler attack surface (fewer components)
- ✅ Azure manages security updates
- ⚠️ Limited to Azure resources

### Service Principal Specific
- ⚠️ More complex configuration
- ✅ Existing security controls from Azure AD
- ✅ Conditional access policies available
- ⚠️ Requires app registration management

## Cost Implications

| Item | Managed Identity | Service Principal |
|------|------------------|-------------------|
| **Identity Creation** | Free | Free |
| **Azure AD Premium** | Not required | Not required (basic features) |
| **Storage Access** | Standard rates | Standard rates |
| **Token Requests** | Free | Free |

**Note**: Both approaches have the same cost for storage access. The identity itself is free in both cases.

## Migration Path

### From Managed Identity to Service Principal
1. Create service principal (Lab 5 setup)
2. Assign same RBAC roles
3. Create federated credentials
4. Update Kubernetes service account annotation
5. Redeploy pods with new service account
6. Test functionality
7. Remove old managed identity

### From Service Principal to Managed Identity
1. Create managed identity (Lab 2 setup)
2. Assign same RBAC roles
3. Create federated credentials
4. Update Kubernetes service account annotation
5. Redeploy pods with new service account
6. Test functionality
7. Remove old service principal

## Common Use Cases

### Managed Identity (Lab 2) is perfect for:
- Simple Azure Storage access
- Azure SQL Database connections
- Azure Key Vault integration
- Azure Cosmos DB access
- Internal Azure service-to-service communication

### Service Principal (Lab 5) is ideal for:
- Microsoft Graph API operations (e.g., reading user data)
- Multi-cloud authentication scenarios
- CI/CD pipeline integrations
- Directory operations (reading groups, users)
- Hybrid cloud architectures
- When app registration is a compliance requirement

## Troubleshooting Comparison

| Issue | Managed Identity | Service Principal |
|-------|------------------|-------------------|
| **Authentication failures** | Check identity exists and federated credential is configured | Check SP exists, not deleted, and has valid federated credential |
| **Permission denied** | Verify RBAC role on resource | Verify RBAC role on resource |
| **Token issues** | Check workload identity enabled on AKS | Check workload identity enabled on AKS |
| **Propagation delays** | 1-2 minutes | 2-5 minutes (Azure AD replication) |
| **Debugging** | Check managed identity logs | Check app registration, check SP status |

## Best Practices

### Managed Identity
1. Use descriptive names for identities
2. Document which resources use each identity
3. Regularly audit RBAC assignments
4. Use separate identities for different environments
5. Enable diagnostic logging

### Service Principal
1. Use descriptive names for app registrations
2. Document the purpose in app description
3. Regularly audit RBAC and API permissions
4. Rotate federated credentials periodically
5. Monitor sign-in logs in Azure AD
6. Use separate service principals per environment
7. Document ownership and maintenance contacts

## Summary

Both approaches are **secure, passwordless, and production-ready**. The choice depends on your specific requirements:

- **Choose Managed Identity (Lab 2)** for simplicity and Azure-only scenarios
- **Choose Service Principal (Lab 5)** for flexibility and advanced scenarios

You can also run **both labs** to understand the differences and determine which approach best fits your organization's needs.
