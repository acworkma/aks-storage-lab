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

@description('Kubernetes version')
param kubernetesVersion string = '1.28.0'

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

// Outputs for use in subsequent labs
output aksClusterName string = aksCluster.name
output aksClusterFqdn string = aksCluster.properties.fqdn
output aksOidcIssuerUrl string = aksCluster.properties.oidcIssuerProfile.issuerURL
output storageAccountName string = storageAccount.name
output storageAccountId string = storageAccount.id
output containerName string = container.name
output kubeletIdentityClientId string = aksCluster.properties.identityProfile.kubeletidentity.clientId
output kubeletIdentityObjectId string = aksCluster.properties.identityProfile.kubeletidentity.objectId
