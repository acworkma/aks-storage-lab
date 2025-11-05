# AKS Storage Lab

This hands-on lab demonstrates how to deploy Azure Kubernetes Service (AKS) and connect it to Azure Storage using managed identities. You'll learn how to securely access Azure Storage from applications running in AKS without managing credentials.

## Overview

In this lab, you will:
- Deploy Azure infrastructure including an AKS cluster and Storage Account
- Configure managed identity / workload identity for secure access between AKS and Azure Storage
- Deploy a sample Python application to validate secure blob access
- (Optional) Deploy a Scala Akka HTTP application with automated Azure Container Registry (ACR) integration (Lab 4)

## Prerequisites

Before starting this lab, you should have:
- An active Azure subscription
- Azure CLI installed ([Install Azure CLI](https://docs.microsoft.com/en-us/cli/azure/install-azure-cli))
- kubectl installed ([Install kubectl](https://kubernetes.io/docs/tasks/tools/))
- Basic knowledge of Kubernetes concepts
- Basic knowledge of Azure services

## Lab Structure

This lab is divided into four parts:

### [Lab 1: Deploy Azure Infrastructure](./lab1-deploy-infrastructure/)
Deploy the necessary Azure resources including:
- Azure Kubernetes Service (AKS) cluster
- Azure Storage Account
- Resource Group and networking components

**Duration:** ~30 minutes

### [Lab 2: Configure Managed Identity](./lab2-configure-identity/)
Set up secure access between AKS and Azure Storage:
- Create and configure managed identity
- Assign appropriate RBAC roles
- Configure workload identity for AKS pods

**Duration:** ~20 minutes

### [Lab 3: Deploy Sample Application](./lab3-sample-app/)
Deploy and validate a Python application that:
- Connects to Azure Storage using managed identity
- Demonstrates secure, credential-free access
- Shows best practices for cloud-native applications

**Duration:** ~20 minutes

### [Lab 4: Scala Application with ACR](./lab4-scala-app/)
Extend the scenario with a production-style Scala (Akka HTTP) application:
- Uses `DefaultAzureCredential` with AKS Workload Identity
- Implements endpoints: `/`, `/health`, `/list`, `/upload`
- Automatically builds image, provisions ACR (if missing), pushes image, and attaches ACR to the AKS cluster
- Demonstrates multi-stage Docker build and registry-driven deployment

**Duration:** ~30–40 minutes (first build + deploy)

## Getting Started

1. Clone this repository:
   ```bash
   git clone https://github.com/acworkma/aks-storage-lab.git
   cd aks-storage-lab
   ```

2. Follow the labs in order, starting with [Lab 1](./lab1-deploy-infrastructure/)

## Architecture

```
┌─────────────────────────────────────────┐
│           Azure Subscription             │
│                                          │
│  ┌────────────────────────────────────┐ │
│  │         Resource Group              │ │
│  │                                     │ │
│  │  ┌──────────────┐  Managed Identity│ │
│  │  │              │◄─────────────────┤ │
│  │  │  AKS Cluster │                   │ │
│  │  │              │                   │ │
│  │  │  ┌────────┐  │                   │ │
│  │  │  │  Pod   │  │  RBAC Roles      │ │
│  │  │  │ Python │  │◄─────────┐       │ │
│  │  │  │  App   │  │          │       │ │
│  │  │  └────────┘  │          │       │ │
│  │  └──────────────┘          │       │ │
│  │                             │       │ │
│  │  ┌──────────────────────┐  │       │ │
│  │  │  Storage Account     │◄─┘       │ │
│  │  │  - Blob Storage      │          │ │
│  │  └──────────────────────┘          │ │
│  └─────────────────────────────────────┘ │
└──────────────────────────────────────────┘
```

## Clean Up

After completing the labs, remember to delete the Azure resources to avoid unnecessary charges. If you ran Lab 4, an Azure Container Registry may also exist.

### Automated Cleanup (Recommended)

Use the provided cleanup script to remove all resources created during the labs:

```bash
./cleanup.sh
```

This script will:
- Remove Kubernetes deployments and services (Lab 3 + Lab 4)
- Delete managed identities and role assignments (Lab 2)
- Delete the entire resource group including AKS cluster, Storage Account, and ACR (Labs 1 & 4)

The script automatically reads from `lab-outputs.env` if available, or prompts for the resource group name.

### Manual Cleanup

If you prefer manual deletion:
```bash
az group delete --name <resource-group-name> --yes --no-wait
```
If you only want to remove the Scala deployment and keep the rest:
```bash
kubectl delete deployment aks-storage-app-scala
kubectl delete service aks-storage-app-scala-service
```
Optionally delete ACR (only if not reused):
```bash
az acr delete -n <acr-name> -g <resource-group-name>
```

## Additional Resources

- [Azure Kubernetes Service Documentation](https://docs.microsoft.com/en-us/azure/aks/)
- [Azure Storage Documentation](https://docs.microsoft.com/en-us/azure/storage/)
- [Workload Identity for AKS](https://docs.microsoft.com/en-us/azure/aks/workload-identity-overview)
- [Azure Managed Identities](https://docs.microsoft.com/en-us/azure/active-directory/managed-identities-azure-resources/)

## Contributing

Contributions are welcome! Please feel free to submit a Pull Request.

## License

This project is licensed under the MIT License - see the LICENSE file for details.