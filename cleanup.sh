#!/bin/bash

# AKS Storage Lab - Cleanup Script
# This script removes all resources created during Labs 1, 2, and 3

set -e  # Exit on error

echo "============================================"
echo "AKS Storage Lab - Cleanup Script"
echo "============================================"
echo ""
echo "This script will remove ALL resources created during the labs:"
echo "  - Kubernetes deployments and services (Lab 3)"
echo "  - Managed identities and role assignments (Lab 2)"
echo "  - AKS cluster, Storage Account, and Resource Group (Lab 1)"
echo ""

# Check if lab-outputs.env exists
LAB_ENV="./lab-outputs.env"
if [ ! -f "$LAB_ENV" ]; then
    echo "Warning: $LAB_ENV not found."
    echo "You'll need to provide resource names manually or the script will use defaults."
    echo ""
    
    # Prompt for resource group name
    read -p "Enter Resource Group name (or press Enter to use default 'rg-aks-storage-lab-wus3'): " RESOURCE_GROUP_INPUT
    RESOURCE_GROUP="${RESOURCE_GROUP_INPUT:-rg-aks-storage-lab-wus3}"
else
    # Load environment variables from file
    set -a
    source "$LAB_ENV"
    set +a
    echo "Loaded configuration from $LAB_ENV"
fi

# Check if Azure CLI is installed
if ! command -v az &> /dev/null; then
    echo "Error: Azure CLI is not installed. Please install it first."
    exit 1
fi

# Check if user is logged in
echo "Checking Azure login status..."
az account show &> /dev/null || {
    echo "Please login to Azure:"
    az login
}

echo ""
echo "Resources to be deleted:"
echo "  Resource Group: ${RESOURCE_GROUP:-<not set>}"
echo "  AKS Cluster: ${AKS_CLUSTER_NAME:-<not set>}"
echo "  Storage Account: ${STORAGE_ACCOUNT_NAME:-<not set>}"
echo "  Managed Identity: ${MANAGED_IDENTITY_NAME:-<not set>}"
echo ""

# Confirmation prompt
read -p "Are you sure you want to delete ALL these resources? (yes/no): " CONFIRM
if [ "$CONFIRM" != "yes" ]; then
    echo "Cleanup cancelled."
    exit 0
fi

echo ""
echo "Starting cleanup process..."
echo ""

# Lab 3: Clean up Kubernetes resources
echo "============================================"
echo "Lab 3: Cleaning up Kubernetes resources..."
echo "============================================"
echo ""

# Check if kubectl is available
if command -v kubectl &> /dev/null; then
    # Check if we're connected to the cluster
    if kubectl cluster-info &> /dev/null; then
        echo "Step 1: Deleting Kubernetes deployment and service..."
        
        # Delete the application deployment
        if kubectl get deployment "${APP_DEPLOYMENT_NAME:-aks-storage-app}" -n "${APP_NAMESPACE:-default}" &> /dev/null; then
            kubectl delete deployment "${APP_DEPLOYMENT_NAME:-aks-storage-app}" -n "${APP_NAMESPACE:-default}" || echo "  Deployment already deleted or not found"
        else
            echo "  Deployment not found (already deleted or never created)"
        fi
        
        # Delete the application service
        if kubectl get service "${APP_SERVICE_NAME:-aks-storage-app-service}" -n "${APP_NAMESPACE:-default}" &> /dev/null; then
            kubectl delete service "${APP_SERVICE_NAME:-aks-storage-app-service}" -n "${APP_NAMESPACE:-default}" || echo "  Service already deleted or not found"
        else
            echo "  Service not found (already deleted or never created)"
        fi
        
        # Delete the service account
        if kubectl get serviceaccount "${SERVICE_ACCOUNT_NAME:-workload-identity-sa}" -n "${SERVICE_ACCOUNT_NAMESPACE:-default}" &> /dev/null; then
            kubectl delete serviceaccount "${SERVICE_ACCOUNT_NAME:-workload-identity-sa}" -n "${SERVICE_ACCOUNT_NAMESPACE:-default}" || echo "  Service account already deleted or not found"
        else
            echo "  Service account not found (already deleted or never created)"
        fi
        
        echo "  Kubernetes resources cleaned up successfully"
    else
        echo "  Not connected to Kubernetes cluster. Skipping Kubernetes cleanup."
        echo "  (Resources will be deleted when the AKS cluster is removed)"
    fi
else
    echo "  kubectl not found. Skipping Kubernetes cleanup."
    echo "  (Resources will be deleted when the AKS cluster is removed)"
fi

echo ""

# Lab 2: Clean up Managed Identity resources
echo "============================================"
echo "Lab 2: Cleaning up Managed Identity..."
echo "============================================"
echo ""

if [ -n "$RESOURCE_GROUP" ] && [ -n "$MANAGED_IDENTITY_NAME" ]; then
    # Check if resource group exists
    if az group show --name "$RESOURCE_GROUP" &> /dev/null; then
        # Check if managed identity exists
        if az identity show --name "$MANAGED_IDENTITY_NAME" --resource-group "$RESOURCE_GROUP" &> /dev/null 2>&1; then
            echo "Step 2: Deleting federated identity credentials..."
            # List and delete federated credentials
            FEDERATED_CREDS=$(az identity federated-credential list \
                --identity-name "$MANAGED_IDENTITY_NAME" \
                --resource-group "$RESOURCE_GROUP" \
                --query '[].name' -o tsv 2>/dev/null || echo "")
            
            if [ -n "$FEDERATED_CREDS" ]; then
                for CRED in $FEDERATED_CREDS; do
                    echo "  Deleting federated credential: $CRED"
                    az identity federated-credential delete \
                        --name "$CRED" \
                        --identity-name "$MANAGED_IDENTITY_NAME" \
                        --resource-group "$RESOURCE_GROUP" \
                        --yes || echo "  Failed to delete $CRED"
                done
            else
                echo "  No federated credentials found"
            fi
            
            echo ""
            echo "Step 3: Deleting role assignments..."
            # Get the client ID to find role assignments
            if [ -n "$AZURE_CLIENT_ID" ]; then
                ROLE_ASSIGNMENTS=$(az role assignment list --assignee "$AZURE_CLIENT_ID" --query '[].id' -o tsv 2>/dev/null || echo "")
                if [ -n "$ROLE_ASSIGNMENTS" ]; then
                    for ASSIGNMENT in $ROLE_ASSIGNMENTS; do
                        echo "  Deleting role assignment: $ASSIGNMENT"
                        az role assignment delete --ids "$ASSIGNMENT" || echo "  Failed to delete role assignment"
                    done
                else
                    echo "  No role assignments found"
                fi
            else
                echo "  AZURE_CLIENT_ID not set, skipping role assignment cleanup"
            fi
            
            echo ""
            echo "Step 4: Deleting managed identity..."
            az identity delete \
                --name "$MANAGED_IDENTITY_NAME" \
                --resource-group "$RESOURCE_GROUP" || echo "  Failed to delete managed identity"
            
            echo "  Managed identity resources cleaned up successfully"
        else
            echo "  Managed identity not found (already deleted or never created)"
        fi
    else
        echo "  Resource group not found (already deleted)"
    fi
else
    echo "  Resource group or managed identity name not set. Skipping Lab 2 cleanup."
    echo "  (Resources will be deleted when the resource group is removed)"
fi

echo ""

# Lab 1: Clean up Azure Infrastructure
echo "============================================"
echo "Lab 1: Cleaning up Azure Infrastructure..."
echo "============================================"
echo ""

if [ -n "$RESOURCE_GROUP" ]; then
    # Check if resource group exists
    if az group show --name "$RESOURCE_GROUP" &> /dev/null; then
        echo "Step 5: Deleting entire Resource Group (includes AKS cluster and Storage Account)..."
        echo "  This may take several minutes..."
        
        az group delete \
            --name "$RESOURCE_GROUP" \
            --yes \
            --no-wait
        
        echo "  Resource group deletion initiated (running in background)"
        echo ""
        echo "  Note: The deletion is running asynchronously. You can check status with:"
        echo "    az group show --name $RESOURCE_GROUP"
    else
        echo "  Resource group not found (already deleted or never created)"
    fi
else
    echo "  Resource group name not set. Cannot delete resources."
    echo "  Please manually delete the resource group if it exists."
fi

echo ""
echo "============================================"
echo "Cleanup Complete!"
echo "============================================"
echo ""
echo "Summary:"
echo "  ✓ Lab 3: Kubernetes resources removed"
echo "  ✓ Lab 2: Managed identity and role assignments removed"
echo "  ✓ Lab 1: Resource group deletion initiated"
echo ""
echo "Note: Azure resource deletion runs asynchronously and may take"
echo "several minutes to complete. You can check the status with:"
echo "  az group list --query \"[?name=='$RESOURCE_GROUP']\" -o table"
echo ""

# Optionally remove the lab-outputs.env file
if [ -f "$LAB_ENV" ]; then
    read -p "Delete lab-outputs.env file? (yes/no): " DELETE_ENV
    if [ "$DELETE_ENV" == "yes" ]; then
        rm -f "$LAB_ENV"
        echo "  lab-outputs.env deleted"
    else
        echo "  lab-outputs.env retained"
    fi
fi

echo ""
echo "All cleanup operations completed!"
echo ""
