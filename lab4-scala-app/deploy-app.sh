#!/bin/bash

# AKS Storage Lab 4 - Deploy Scala Application Script

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

# Additional variables for this lab (use dedicated variable names to avoid env file conflicts)
CONTAINER_NAME="data"
SCALA_APP_IMAGE_TAG="${SCALA_APP_IMAGE_TAG:-latest}"

# ACR automation variables (user may export ACR_NAME beforehand to override)
ACR_NAME="${ACR_NAME:-}"  # if empty we'll derive &/or create
CREATE_ACR="${CREATE_ACR:-true}"  # allow disabling creation if registry already exists
ATTACH_ACR="${ATTACH_ACR:-true}"  # allow disabling attach step

# Will be set later after potential ACR creation/push
SCALA_APP_IMAGE="${SCALA_APP_IMAGE:-aks-storage-app-scala:$SCALA_APP_IMAGE_TAG}"

echo "================================================"
echo "AKS Storage Lab 4 - Deploy Scala Application"
echo "================================================"
echo ""

echo "Configuration (initial):"
echo "  Resource Group: $RESOURCE_GROUP"
echo "  AKS Cluster:    $AKS_CLUSTER_NAME"
echo "  Storage Account: $STORAGE_ACCOUNT_NAME"
echo "  Service Account:  $SERVICE_ACCOUNT_NAME"
echo "  Container:        $CONTAINER_NAME"
echo "  ACR Name (req?):  ${ACR_NAME:-<to-be-derived>}"
echo "  Image (initial):  $SCALA_APP_IMAGE"
echo ""

# Check if kubectl is available
if ! command -v kubectl &> /dev/null; then
    echo "Error: kubectl is not installed"
    exit 1
fi

#############################################
# Step 1: (Optional) Create / Ensure ACR
#############################################
echo "Step 1: Ensuring Azure Container Registry (ACR) is available..."

LOGIN_SERVER=""
if [ "$CREATE_ACR" = "true" ]; then
    if [ -z "$ACR_NAME" ]; then
        # Derive a name from resource group (remove hyphens, append 'acr') and truncate to 45 chars
        DERIVED_BASE="${RESOURCE_GROUP//-/}acr"
        # Ensure lowercase alphanumeric only (ACR requirement)
        DERIVED_BASE="$(echo "$DERIVED_BASE" | tr -cd '[:alnum:]')"
        # Truncate
        ACR_NAME="${DERIVED_BASE:0:45}"
        # Guarantee minimum length 5 (if RG was too short)
        if [ ${#ACR_NAME} -lt 5 ]; then
            ACR_NAME="${ACR_NAME}labs"
        fi
    fi

    echo "  Target ACR Name: $ACR_NAME"
    if az acr show -n "$ACR_NAME" >/dev/null 2>&1; then
        echo "  ACR already exists. Skipping creation."
    else
        echo "  ACR not found. Creating..."
        RG_LOCATION="$(az group show -n "$RESOURCE_GROUP" --query location -o tsv)"
        if [ -z "$RG_LOCATION" ]; then
            echo "Error: Unable to determine resource group location; ensure you are logged in (az login) and RG exists." >&2
            exit 3
        fi
        az acr create -n "$ACR_NAME" -g "$RESOURCE_GROUP" --sku Basic --location "$RG_LOCATION" --output none
        echo "  ACR created successfully."
    fi
    LOGIN_SERVER="$(az acr show -n "$ACR_NAME" --query loginServer -o tsv)"
else
    echo "  CREATE_ACR=false; skipping ACR creation logic."
    if [ -n "$ACR_NAME" ]; then
        LOGIN_SERVER="$(az acr show -n "$ACR_NAME" --query loginServer -o tsv 2>/dev/null || echo "")"
    fi
fi

if [ -n "$ACR_NAME" ] && [ -z "$LOGIN_SERVER" ]; then
    echo "Warning: Could not resolve login server for ACR $ACR_NAME. Image push will be skipped." >&2
fi

#############################################
# Step 2: Build local image if missing
#############################################
echo "Step 2: Checking / building Docker image..."
BASE_LOCAL_IMAGE="aks-storage-app-scala"
if docker images "$BASE_LOCAL_IMAGE" | grep -q "$SCALA_APP_IMAGE_TAG"; then
    echo "  Local image found: $BASE_LOCAL_IMAGE:$SCALA_APP_IMAGE_TAG"
else
    echo "  Local image not found. Building..."
    echo "  This may take a few minutes (sbt compilation + assembly)."
    docker build -t "$BASE_LOCAL_IMAGE:$SCALA_APP_IMAGE_TAG" "$SCRIPT_DIR"
    echo "  Build complete!"
fi

#############################################
# Step 3: Tag & push to ACR (if available)
#############################################
if [ -n "$LOGIN_SERVER" ]; then
    echo "Step 3: Tagging and pushing image to ACR..."
    ACR_IMAGE_REF="$LOGIN_SERVER/$BASE_LOCAL_IMAGE:$SCALA_APP_IMAGE_TAG"
    echo "  ACR Image Ref: $ACR_IMAGE_REF"
    # az acr login (tokenless if Azure CLI is logged in)
    az acr login --name "$ACR_NAME" --output none
    docker tag "$BASE_LOCAL_IMAGE:$SCALA_APP_IMAGE_TAG" "$ACR_IMAGE_REF"
    docker push "$ACR_IMAGE_REF"
    SCALA_APP_IMAGE="$ACR_IMAGE_REF"
    echo "  Push complete."
    if [ "$ATTACH_ACR" = "true" ]; then
        echo "  Attaching ACR to AKS cluster (for pull permissions)..."
        az aks update -n "$AKS_CLUSTER_NAME" -g "$RESOURCE_GROUP" --attach-acr "$ACR_NAME" --output none
        echo "  ACR attached to AKS cluster."
    else
        echo "  ATTACH_ACR=false; skipped attach step."
    fi
else
    echo "Step 3: Skipped ACR push (no login server). Using local image reference: $SCALA_APP_IMAGE"
fi

echo ""
echo "Resolved Image to Deploy: $SCALA_APP_IMAGE"
echo ""

echo "Step 4: Preparing deployment manifest substitutions..."

# Validate manifest exists
if [ ! -f "$K8S_DIR/deployment.yaml" ]; then
  echo "Error: deployment manifest not found at $K8S_DIR/deployment.yaml" >&2
  exit 2
fi

# Use sed to substitute environment variables
if [ -n "$LOGIN_SERVER" ]; then
    sed -e "s/workload-identity-sa/$SERVICE_ACCOUNT_NAME/g" \
            -e "s/<your-storage-account-name>/$STORAGE_ACCOUNT_NAME/g" \
            -e "s|image: aks-storage-app-scala:latest|image: $SCALA_APP_IMAGE|g" \
            -e "s/imagePullPolicy: Never/imagePullPolicy: Always/g" \
            "$K8S_DIR/deployment.yaml" > /tmp/deployment-scala-temp.yaml
else
    sed -e "s/workload-identity-sa/$SERVICE_ACCOUNT_NAME/g" \
            -e "s/<your-storage-account-name>/$STORAGE_ACCOUNT_NAME/g" \
            -e "s|image: aks-storage-app-scala:latest|image: $SCALA_APP_IMAGE|g" \
            "$K8S_DIR/deployment.yaml" > /tmp/deployment-scala-temp.yaml
fi

echo "Step 5: Deploying Scala application to Kubernetes..."
kubectl apply -f /tmp/deployment-scala-temp.yaml
kubectl apply -f "$K8S_DIR/service.yaml"

echo ""
echo "Step 6: Waiting for deployment to be ready..."
kubectl rollout status deployment/aks-storage-app-scala --timeout=300s

echo ""
echo "Step 7: Getting application information..."
kubectl get deployment aks-storage-app-scala
kubectl get pods -l app=aks-storage-app-scala
kubectl get service aks-storage-app-scala-service

echo ""
echo "Step 8: Waiting for external IP (this may take a few minutes)..."
echo "Waiting for LoadBalancer IP..."

# Wait for external IP with timeout
TIMEOUT=300
ELAPSED=0
while true; do
    EXTERNAL_IP=$(kubectl get service aks-storage-app-scala-service -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "")
    
    if [ -n "$EXTERNAL_IP" ]; then
        break
    fi
    
    if [ $ELAPSED -ge $TIMEOUT ]; then
        echo "Timeout waiting for external IP. Check service status manually:"
        echo "  kubectl get service aks-storage-app-scala-service"
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
    echo "  kubectl get service aks-storage-app-scala-service"
fi

echo "View logs:"
echo "  kubectl logs -l app=aks-storage-app-scala --tail=50"
echo ""
echo "View pods:"
echo "  kubectl get pods -l app=aks-storage-app-scala"
echo ""

# Append Lab 4 outputs to the shared env file (repo root)
{
    echo ""
    echo "# Lab 4 outputs - Scala application deployment"
    echo "SCALA_CONTAINER_NAME=$CONTAINER_NAME"
    echo "SCALA_APP_IMAGE=$SCALA_APP_IMAGE"
    echo "SCALA_APP_DEPLOYMENT_NAME=aks-storage-app-scala"
    echo "SCALA_APP_SERVICE_NAME=aks-storage-app-scala-service"
    echo "SCALA_APP_NAMESPACE=default"
    if [ -n "$EXTERNAL_IP" ]; then
        echo "SCALA_APP_EXTERNAL_IP=$EXTERNAL_IP"
    fi
    if [ -n "$ACR_NAME" ]; then
        echo "ACR_NAME=$ACR_NAME"
        [ -n "$LOGIN_SERVER" ] && echo "ACR_LOGIN_SERVER=$LOGIN_SERVER"
    fi
} >> "$LAB_ENV"
echo "Lab 4 outputs appended to $LAB_ENV"
echo ""

# Clean up temp file
rm -f /tmp/deployment-scala-temp.yaml

echo "Note: The Scala app uses Akka HTTP and has all endpoints: /, /health, /list, /upload"
echo ""
