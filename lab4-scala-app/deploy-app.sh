#!/bin/bash

# AKS Storage Lab 4 - Deploy Scala Application Script
# Builds Scala app, pushes to ACR, and deploys to AKS

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
    echo "Error: $LAB_ENV not found. Please run Lab 1 and Lab 2 first."
    exit 1
fi

# Lab 4 specific variables
APP_NAMESPACE="lab4"
APP_NAME="aks-storage-app-scala"
APP_IMAGE_TAG="${SCALA_APP_IMAGE_TAG:-latest}"
CONTAINER_NAME="${CONTAINER_NAME:-data}"

echo "================================================"
echo "AKS Storage Lab 4 - Deploy Scala Application"
echo "================================================"
echo ""

echo "Configuration:"
echo "  Resource Group: $RESOURCE_GROUP"
echo "  AKS Cluster: $AKS_CLUSTER_NAME"
echo "  ACR: $ACR_NAME"
echo "  ACR Login Server: $ACR_LOGIN_SERVER"
echo "  Storage Account: $STORAGE_ACCOUNT_NAME"
echo "  Service Account: $SERVICE_ACCOUNT_NAME"
echo "  Namespace: $APP_NAMESPACE"
echo "  Container: $CONTAINER_NAME"
echo ""

# Validate required variables
for var in STORAGE_ACCOUNT_NAME ACR_NAME ACR_LOGIN_SERVER SERVICE_ACCOUNT_NAME; do
    if [ -z "${!var}" ]; then
        echo "Error: $var not set. Please ensure Labs 1 and 2 completed successfully."
        exit 1
    fi
done

# Check prerequisites
if ! command -v kubectl &> /dev/null; then
    echo "Error: kubectl is not installed"
    exit 1
fi

if ! command -v docker &> /dev/null; then
    echo "Error: docker is not installed"
    exit 1
fi

echo "Step 1: Building Docker image..."
echo "  This may take a few minutes (sbt compilation + assembly)."
docker build -t "$APP_NAME:$APP_IMAGE_TAG" "$SCRIPT_DIR"

echo ""
echo "Step 2: Logging into ACR..."
az acr login --name "$ACR_NAME" --output none

echo ""
echo "Step 3: Tagging and pushing image to ACR..."
ACR_IMAGE="$ACR_LOGIN_SERVER/$APP_NAME:$APP_IMAGE_TAG"
docker tag "$APP_NAME:$APP_IMAGE_TAG" "$ACR_IMAGE"
docker push "$ACR_IMAGE"
echo "  Pushed: $ACR_IMAGE"

echo ""
echo "Step 4: Ensuring AKS can pull from ACR..."
az aks update -n "$AKS_CLUSTER_NAME" -g "$RESOURCE_GROUP" --attach-acr "$ACR_NAME" --output none 2>/dev/null || true

echo ""
echo "Step 5: Applying Kubernetes manifests..."

# Substitute placeholders and apply deployment
sed -e "s|image: aks-storage-app-scala:latest|image: $ACR_IMAGE|g" \
    -e "s/<your-storage-account-name>/$STORAGE_ACCOUNT_NAME/g" \
    -e "s/<your-container-name>/$CONTAINER_NAME/g" \
    -e "s/serviceAccountName: workload-identity-sa/serviceAccountName: $SERVICE_ACCOUNT_NAME/g" \
    -e "s/imagePullPolicy: Never/imagePullPolicy: Always/g" \
    "$K8S_DIR/deployment.yaml" | kubectl apply -f -

kubectl apply -f "$K8S_DIR/service.yaml"

echo ""
echo "Step 6: Waiting for deployment to be ready..."
kubectl rollout status deployment/aks-storage-app-scala -n "$APP_NAMESPACE" --timeout=300s

echo ""
echo "Step 7: Getting application information..."
kubectl get deployment aks-storage-app-scala -n "$APP_NAMESPACE"
kubectl get pods -l app=aks-storage-app-scala -n "$APP_NAMESPACE"
kubectl get service aks-storage-app-scala-service -n "$APP_NAMESPACE"

echo ""
echo "Step 8: Waiting for external IP (this may take a few minutes)..."
echo "Waiting for LoadBalancer IP..."

# Wait for external IP with timeout
TIMEOUT=300
ELAPSED=0
while true; do
    EXTERNAL_IP=$(kubectl get service aks-storage-app-scala-service -n "$APP_NAMESPACE" -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "")
    
    if [ -n "$EXTERNAL_IP" ]; then
        break
    fi
    
    if [ $ELAPSED -ge $TIMEOUT ]; then
        echo "Timeout waiting for external IP. Check service status manually:"
        echo "  kubectl get service aks-storage-app-scala-service -n $APP_NAMESPACE"
        break
    fi
    
    echo "Still waiting... ($ELAPSED seconds elapsed)"
    sleep 10
    ELAPSED=$((ELAPSED + 10))
done

echo ""
echo "================================================"
echo "Deployment Complete!"
echo "================================================"
echo ""

if [ -n "$EXTERNAL_IP" ]; then
    echo "Application URL: http://$EXTERNAL_IP"
    echo ""
    echo "Test the Scala application:"
    echo "  Home:          curl http://$EXTERNAL_IP/"
    echo "  Health check:  curl http://$EXTERNAL_IP/health"
    echo "  List blobs:    curl http://$EXTERNAL_IP/list"
    echo "  Upload file:   curl -X POST http://$EXTERNAL_IP/upload"
    echo ""
else
    echo "External IP not yet assigned. Check status with:"
    echo "  kubectl get service aks-storage-app-scala-service -n $APP_NAMESPACE"
fi

echo "View logs:"
echo "  kubectl logs -l app=aks-storage-app-scala -n $APP_NAMESPACE --tail=50"
echo ""
echo "View pods:"
echo "  kubectl get pods -l app=aks-storage-app-scala -n $APP_NAMESPACE"
echo ""

# Append Lab 4 outputs to the shared env file (repo root)
if grep -q "# Lab 4 outputs" "$LAB_ENV"; then
  echo "Lab 4 outputs already exist in $LAB_ENV. Skipping append."
else
  {
      echo ""
      echo "# Lab 4 outputs - Scala application deployment"
      echo "SCALA_APP_NAMESPACE=$APP_NAMESPACE"
      echo "SCALA_CONTAINER_NAME=$CONTAINER_NAME"
      echo "SCALA_APP_IMAGE=$ACR_IMAGE"
      echo "SCALA_APP_DEPLOYMENT_NAME=aks-storage-app-scala"
      echo "SCALA_APP_SERVICE_NAME=aks-storage-app-scala-service"
      if [ -n "$EXTERNAL_IP" ]; then
          echo "SCALA_APP_EXTERNAL_IP=$EXTERNAL_IP"
      fi
  } >> "$LAB_ENV"
  echo "Lab 4 outputs appended to $LAB_ENV"
fi
echo ""

echo "Note: The Scala app uses Akka HTTP and has all endpoints: /, /health, /list, /upload"
echo ""
