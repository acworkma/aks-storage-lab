@description('Name of the AKS cluster')
param aksClusterName string

@description('Azure region for resources')
param location string = resourceGroup().location

@description('Name of the storage account (must be globally unique)')
param storageAccountName string

@description('Number of nodes in the AKS cluster')
param nodeCount int = 2

@description('VM size for AKS nodes')
param nodeVmSize string = 'Standard_DS2_v2'

@description('Kubernetes version - defaults to a recent stable version')
param kubernetesVersion string = '1.30.0'

@description('Name of the Key Vault (must be globally unique, 3-24 chars)')
param keyVaultName string

@description('Name of the Azure Container Registry (must be globally unique, alphanumeric only)')
param acrName string

@description('Deploy Key Vault (set to false to skip)')
param deployKeyVault bool = true

@description('Deploy Azure Container Registry (set to false to skip)')
param deployAcr bool = true

// Create Storage Account
resource storageAccount 'Microsoft.Storage/storageAccounts@2023-01-01' = {
  name: storageAccountName
  location: location
  sku: {
    name: 'Standard_LRS'
  }
  kind: 'StorageV2'
  properties: {
    accessTier: 'Hot'
    allowBlobPublicAccess: false
    minimumTlsVersion: 'TLS1_2'
    supportsHttpsTrafficOnly: true
  }
}

// Create a container in the storage account
resource blobService 'Microsoft.Storage/storageAccounts/blobServices@2023-01-01' = {
  parent: storageAccount
  name: 'default'
}

resource container 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-01-01' = {
  parent: blobService
  name: 'data'
  properties: {
    publicAccess: 'None'
  }
}

// Create Key Vault for secrets management
resource keyVault 'Microsoft.KeyVault/vaults@2023-07-01' = if (deployKeyVault) {
  name: keyVaultName
  location: location
  properties: {
    sku: {
      family: 'A'
      name: 'standard'
    }
    tenantId: subscription().tenantId
    enableRbacAuthorization: true
    enableSoftDelete: true
    softDeleteRetentionInDays: 90
    enablePurgeProtection: true
    publicNetworkAccess: 'Enabled'
  }
}

// Create Azure Container Registry for container images
resource acr 'Microsoft.ContainerRegistry/registries@2023-07-01' = if (deployAcr) {
  name: acrName
  location: location
  sku: {
    name: 'Basic'
  }
  properties: {
    adminUserEnabled: false
    publicNetworkAccess: 'Enabled'
  }
}

// Create AKS Cluster
resource aksCluster 'Microsoft.ContainerService/managedClusters@2023-10-01' = {
  name: aksClusterName
  location: location
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    dnsPrefix: aksClusterName
    kubernetesVersion: kubernetesVersion
    enableRBAC: true
    
    // Enable workload identity and OIDC issuer for managed identity
    oidcIssuerProfile: {
      enabled: true
    }
    securityProfile: {
      workloadIdentity: {
        enabled: true
      }
    }
    
    agentPoolProfiles: [
      {
        name: 'agentpool'
        count: nodeCount
        vmSize: nodeVmSize
        osType: 'Linux'
        mode: 'System'
        enableAutoScaling: false
      }
    ]
    
    networkProfile: {
      networkPlugin: 'azure'
      networkPolicy: 'azure'
      serviceCidr: '10.0.0.0/16'
      dnsServiceIP: '10.0.0.10'
    }
  }
}

// Grant AKS kubelet identity AcrPull role on ACR
resource acrPullRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (deployAcr) {
  name: guid(acr.id, aksCluster.id, '7f951dda-4ed3-4680-a7ca-43fe172d538d')
  scope: acr
  properties: {
    principalId: aksCluster.properties.identityProfile.kubeletidentity.objectId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '7f951dda-4ed3-4680-a7ca-43fe172d538d') // AcrPull
  }
}

// Outputs for use in subsequent labs
output aksClusterName string = aksCluster.name
output aksClusterFqdn string = aksCluster.properties.fqdn
output aksOidcIssuerUrl string = aksCluster.properties.oidcIssuerProfile.issuerURL
output storageAccountName string = storageAccount.name
output storageAccountId string = storageAccount.id
output containerName string = container.name
output kubeletIdentityClientId string = aksCluster.properties.identityProfile.kubeletidentity.clientId
output kubeletIdentityObjectId string = aksCluster.properties.identityProfile.kubeletidentity.objectId
output keyVaultName string = deployKeyVault ? keyVault!.name : ''
output keyVaultUri string = deployKeyVault ? keyVault!.properties.vaultUri : ''
output acrName string = deployAcr ? acr!.name : ''
output acrLoginServer string = deployAcr ? acr!.properties.loginServer : ''
