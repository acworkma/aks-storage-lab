#!/bin/bash

# AKS Storage Lab - Deploy Sample Application Script

set -e  # Exit on error

# Variables - Update these to match your environment
RESOURCE_GROUP="rg-aks-storage-lab"
STORAGE_ACCOUNT_NAME="<your-storage-account-name>"  # UPDATE THIS
SERVICE_ACCOUNT_NAME="workload-identity-sa"
CONTAINER_NAME="data"
APP_IMAGE="mcr.microsoft.com/azuredocs/aks-helloworld:v1"  # Placeholder - replace with actual image

echo "================================================"
echo "AKS Storage Lab - Deploy Sample Application"
echo "================================================"
echo ""

# Check if storage account name is still placeholder
if [ "$STORAGE_ACCOUNT_NAME" == "<your-storage-account-name>" ]; then
    echo "Error: Please update STORAGE_ACCOUNT_NAME in this script"
    echo "You can find it by running:"
    echo "  az storage account list -g $RESOURCE_GROUP --query '[0].name' -o tsv"
    exit 1
fi

echo "Configuration:"
echo "  Storage Account: $STORAGE_ACCOUNT_NAME"
echo "  Service Account: $SERVICE_ACCOUNT_NAME"
echo "  Container: $CONTAINER_NAME"
echo ""

# Check if kubectl is available
if ! command -v kubectl &> /dev/null; then
    echo "Error: kubectl is not installed"
    exit 1
fi

echo "Step 1: Updating deployment manifest with storage account name..."

# Create a temporary deployment file with updated values
cat > /tmp/deployment-temp.yaml <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: aks-storage-app
  labels:
    app: aks-storage-app
spec:
  replicas: 2
  selector:
    matchLabels:
      app: aks-storage-app
  template:
    metadata:
      labels:
        app: aks-storage-app
        azure.workload.identity/use: "true"
    spec:
      serviceAccountName: $SERVICE_ACCOUNT_NAME
      containers:
      - name: app
        image: $APP_IMAGE
        imagePullPolicy: Always
        ports:
        - containerPort: 8080
          name: http
        env:
        - name: AZURE_STORAGE_ACCOUNT_NAME
          value: "$STORAGE_ACCOUNT_NAME"
        - name: AZURE_STORAGE_CONTAINER_NAME
          value: "$CONTAINER_NAME"
        resources:
          requests:
            cpu: 100m
            memory: 128Mi
          limits:
            cpu: 500m
            memory: 512Mi
        livenessProbe:
          httpGet:
            path: /health
            port: 8080
          initialDelaySeconds: 30
          periodSeconds: 10
          timeoutSeconds: 5
          failureThreshold: 3
        readinessProbe:
          httpGet:
            path: /health
            port: 8080
          initialDelaySeconds: 10
          periodSeconds: 5
          timeoutSeconds: 3
          failureThreshold: 3
EOF

echo ""
echo "Step 2: Deploying application to Kubernetes..."
kubectl apply -f /tmp/deployment-temp.yaml
kubectl apply -f k8s/service.yaml

echo ""
echo "Step 3: Waiting for deployment to be ready..."
kubectl rollout status deployment/aks-storage-app --timeout=300s

echo ""
echo "Step 4: Getting application information..."
kubectl get deployment aks-storage-app
kubectl get pods -l app=aks-storage-app
kubectl get service aks-storage-app-service

echo ""
echo "Step 5: Waiting for external IP (this may take a few minutes)..."
echo "Waiting for LoadBalancer IP..."

# Wait for external IP with timeout
TIMEOUT=300
ELAPSED=0
while true; do
    EXTERNAL_IP=$(kubectl get service aks-storage-app-service -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "")
    
    if [ -n "$EXTERNAL_IP" ]; then
        break
    fi
    
    if [ $ELAPSED -ge $TIMEOUT ]; then
        echo "Timeout waiting for external IP. Check service status manually:"
        echo "  kubectl get service aks-storage-app-service"
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
    echo "Test the application:"
    echo "  Health check:  curl http://$EXTERNAL_IP/health"
    echo "  List blobs:    curl http://$EXTERNAL_IP/list"
    echo "  Upload file:   curl -X POST http://$EXTERNAL_IP/upload"
    echo ""
else
    echo "External IP not yet assigned. Check status with:"
    echo "  kubectl get service aks-storage-app-service"
fi

echo "View logs:"
echo "  kubectl logs -l app=aks-storage-app --tail=50"
echo ""
echo "View pods:"
echo "  kubectl get pods -l app=aks-storage-app"
echo ""

# Clean up temp file
rm -f /tmp/deployment-temp.yaml
