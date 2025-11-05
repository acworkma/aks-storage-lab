#!/bin/bash

# Helper script to push Scala app image to Azure Container Registry

set -e

echo "==========================================="
echo "Push Scala App to Azure Container Registry"
echo "==========================================="
echo ""

# Check if ACR_NAME is provided
if [ -z "$1" ]; then
    echo "Usage: bash push-to-acr.sh <acr-name> [tag]"
    echo ""
    echo "Example:"
    echo "  bash push-to-acr.sh myacrname v1"
    echo ""
    exit 1
fi

ACR_NAME="$1"
IMAGE_TAG="${2:-v1}"
LOCAL_IMAGE="aks-storage-app-scala:latest"
ACR_IMAGE="$ACR_NAME.azurecr.io/aks-storage-app-scala:$IMAGE_TAG"

echo "Configuration:"
echo "  ACR Name: $ACR_NAME"
echo "  Local Image: $LOCAL_IMAGE"
echo "  ACR Image: $ACR_IMAGE"
echo ""

# Check if local image exists
if ! docker images "$LOCAL_IMAGE" | grep -q "latest"; then
    echo "Error: Local image $LOCAL_IMAGE not found."
    echo "Build it first with: docker build -t $LOCAL_IMAGE ."
    exit 1
fi

# Login to ACR
echo "Step 1: Logging in to ACR..."
az acr login --name "$ACR_NAME"

# Tag image
echo ""
echo "Step 2: Tagging image..."
docker tag "$LOCAL_IMAGE" "$ACR_IMAGE"

# Push image
echo ""
echo "Step 3: Pushing to ACR..."
docker push "$ACR_IMAGE"

echo ""
echo "==========================================="
echo "Push Complete!"
echo "==========================================="
echo ""
echo "Image available at: $ACR_IMAGE"
echo ""
echo "Update your deployment to use this image:"
echo "  sed -i 's|image: aks-storage-app-scala:latest|image: $ACR_IMAGE|g' k8s/deployment.yaml"
echo "  sed -i 's|imagePullPolicy: Never|imagePullPolicy: Always|g' k8s/deployment.yaml"
echo ""
echo "Or set environment variable before deploying:"
echo "  export SCALA_APP_IMAGE=$ACR_IMAGE"
echo "  bash deploy-app.sh"
echo ""
