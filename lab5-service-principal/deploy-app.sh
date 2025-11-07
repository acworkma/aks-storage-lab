#!/bin/bash

# AKS Storage Lab 5 - Deploy Application with Service Principal

set -e  # Exit on error

# Source outputs from previous labs (env file at repo root)
SCRIPT_DIR="$(cd -- "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
LAB_ENV="$REPO_ROOT/lab-outputs.env"
K8S_DIR="$SCRIPT_DIR/k8s"
if [ -f "$LAB_ENV" ]; then
    set -a
    source "$LAB_ENV"
    set +a
else
    echo "Error: $LAB_ENV not found. Please run Lab 1 and Lab 5 service principal setup first."
    exit 1
fi

# Additional variables for this lab
CONTAINER_NAME="data"
APP_IMAGE="python:3.11-slim"

echo "========================================================"
echo "AKS Storage Lab 5 - Deploy Application (Service Principal)"
echo "========================================================"
echo ""

echo "Configuration:"
echo "  Storage Account: $STORAGE_ACCOUNT_NAME"
echo "  Service Account: $SP_SERVICE_ACCOUNT_NAME"
echo "  Service Principal: $SP_NAME"
echo "  Container: $CONTAINER_NAME"
echo ""

# Check if kubectl is available
if ! command -v kubectl &> /dev/null; then
    echo "Error: kubectl is not installed"
    exit 1
fi

echo "Step 1: Updating deployment manifest with storage account name..."

# Use the existing deployment file and substitute environment variables
if [ ! -f "$K8S_DIR/deployment.yaml" ]; then
    echo "Error: deployment manifest not found at $K8S_DIR/deployment.yaml" >&2
    exit 2
fi
sed -e "s/sp-workload-identity-sa/$SP_SERVICE_ACCOUNT_NAME/g" \
        -e "s/<your-storage-account-name>/$STORAGE_ACCOUNT_NAME/g" \
        "$K8S_DIR/deployment.yaml" > /tmp/deployment-sp-temp.yaml

echo ""
echo "Step 2: Deploying application to Kubernetes..."
kubectl apply -f /tmp/deployment-sp-temp.yaml
kubectl apply -f "$K8S_DIR/service.yaml"

echo ""
echo "Step 3: Waiting for deployment to be ready..."
kubectl rollout status deployment/aks-storage-app-sp --timeout=300s

echo ""
echo "Step 4: Getting application information..."
kubectl get deployment aks-storage-app-sp
kubectl get pods -l app=aks-storage-app-sp
kubectl get service aks-storage-app-sp-service

echo ""
echo "Step 5: Waiting for external IP (this may take a few minutes)..."
echo "Waiting for LoadBalancer IP..."

# Wait for external IP with timeout
TIMEOUT=300
ELAPSED=0
while true; do
    EXTERNAL_IP=$(kubectl get service aks-storage-app-sp-service -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "")
    
    if [ -n "$EXTERNAL_IP" ]; then
        break
    fi
    
    if [ $ELAPSED -ge $TIMEOUT ]; then
        echo "Timeout waiting for external IP. Check service status manually:"
        echo "  kubectl get service aks-storage-app-sp-service"
        break
    fi
    
    echo "Still waiting... ($ELAPSED seconds elapsed)"
    sleep 10
    ELAPSED=$((ELAPSED + 10))
done

echo ""
echo "========================================================"
echo "Deployment Complete!"
echo "========================================================"
echo ""

if [ -n "$EXTERNAL_IP" ]; then
    echo "Application URL: http://$EXTERNAL_IP"
    echo ""
    echo "Test the application:"
    echo "  Home page:     curl http://$EXTERNAL_IP/"
    echo "  Health check:  curl http://$EXTERNAL_IP/health"
    echo "  List blobs:    curl http://$EXTERNAL_IP/list"
    echo "  Upload file:   curl http://$EXTERNAL_IP/upload"
    echo ""
else
    echo "External IP not yet assigned. Check status with:"
    echo "  kubectl get service aks-storage-app-sp-service"
fi

echo "View logs:"
echo "  kubectl logs -l app=aks-storage-app-sp --tail=50"
echo ""
echo "View pods:"
echo "  kubectl get pods -l app=aks-storage-app-sp"
echo ""

# Append Lab 5 application outputs to the shared env file (repo root)
# Remove old Lab 5 app outputs if they exist
sed -i '/# Lab 5 app outputs/,/^$/d' "$LAB_ENV"

{
    echo ""
    echo "# Lab 5 app outputs - Service Principal application deployment"
    echo "SP_CONTAINER_NAME=$CONTAINER_NAME"
    echo "SP_APP_IMAGE=$APP_IMAGE"
    echo "SP_APP_DEPLOYMENT_NAME=aks-storage-app-sp"
    echo "SP_APP_SERVICE_NAME=aks-storage-app-sp-service"
    echo "SP_APP_NAMESPACE=default"
    if [ -n "$EXTERNAL_IP" ]; then
        echo "SP_APP_EXTERNAL_IP=$EXTERNAL_IP"
    fi
} >> "$LAB_ENV"
echo "Lab 5 application outputs appended to $LAB_ENV"
echo ""

# Clean up temp file
rm -f /tmp/deployment-sp-temp.yaml
