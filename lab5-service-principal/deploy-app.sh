#!/bin/bash

# Lab 5 - Deploy Application Using Service Principal Federation
# Performs manifest substitutions (storage account name), deploys to namespace lab5,
# waits for rollout & external IP, and appends outputs to env file.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
LAB_ENV="$REPO_ROOT/lab-outputs.env"
K8S_DIR="$SCRIPT_DIR/k8s"

if [[ -f "$LAB_ENV" ]]; then
  set -a; source "$LAB_ENV"; set +a
else
  echo "Error: $LAB_ENV not found. Run previous labs first." >&2; exit 1
fi

STORAGE_ACCOUNT_NAME="${STORAGE_ACCOUNT_NAME:-}"
SERVICE_ACCOUNT_NAMESPACE="${LAB5_SERVICE_ACCOUNT_NAMESPACE:-lab5}"
DEPLOYMENT_NAME="aks-storage-app-sp"
SERVICE_NAME="aks-storage-app-sp-service"
CONTAINER_NAME="data"

if [[ -z "$STORAGE_ACCOUNT_NAME" ]]; then
  echo "Error: STORAGE_ACCOUNT_NAME not set in env file." >&2; exit 2
fi

echo "==============================================="
echo "Lab 5 - Deploy Service Principal Application"
echo "==============================================="
echo "Storage Account:   $STORAGE_ACCOUNT_NAME"
echo "Namespace:         $SERVICE_ACCOUNT_NAMESPACE"
echo "Deployment:        $DEPLOYMENT_NAME"
echo "Service:           $SERVICE_NAME"
echo "==============================================="

for bin in kubectl; do
  command -v "$bin" >/dev/null || { echo "Error: $bin not installed" >&2; exit 3; }
done

echo "Step 1: Ensure namespace exists..."
kubectl get namespace "$SERVICE_ACCOUNT_NAMESPACE" &>/dev/null || kubectl create namespace "$SERVICE_ACCOUNT_NAMESPACE"

echo "Step 2: Substitute manifests..."
if [[ ! -f "$K8S_DIR/deployment.yaml" ]]; then
  echo "Error: deployment.yaml missing" >&2; exit 4
fi
sed -e "s/<your-storage-account-name>/$STORAGE_ACCOUNT_NAME/g" \
    "$K8S_DIR/deployment.yaml" > /tmp/lab5-deployment.yaml

if [[ ! -f "$K8S_DIR/service.yaml" ]]; then
  echo "Error: service.yaml missing" >&2; exit 5
fi
cp "$K8S_DIR/service.yaml" /tmp/lab5-service.yaml

echo "Step 3: Apply manifests..."
kubectl apply -f /tmp/lab5-deployment.yaml
kubectl apply -f /tmp/lab5-service.yaml

echo "Step 4: Wait for rollout..."
kubectl rollout status deployment/$DEPLOYMENT_NAME -n "$SERVICE_ACCOUNT_NAMESPACE" --timeout=300s

echo "Step 5: Gather info..."
kubectl get deployment $DEPLOYMENT_NAME -n "$SERVICE_ACCOUNT_NAMESPACE"
kubectl get pods -n "$SERVICE_ACCOUNT_NAMESPACE" -l app=$DEPLOYMENT_NAME
kubectl get service $SERVICE_NAME -n "$SERVICE_ACCOUNT_NAMESPACE"

echo "Step 6: Wait for external IP..."
TIMEOUT=300; ELAPSED=0; EXTERNAL_IP=""
while true; do
  EXTERNAL_IP=$(kubectl get service $SERVICE_NAME -n "$SERVICE_ACCOUNT_NAMESPACE" -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "")
  [[ -n "$EXTERNAL_IP" ]] && break
  if (( ELAPSED >= TIMEOUT )); then
    echo "Timeout waiting for external IP."; break
  fi
  echo "  Waiting... ($ELAPSED s)"
  sleep 10; ELAPSED=$((ELAPSED+10))
done

echo "==============================================="
echo "Deployment Complete"
echo "==============================================="
if [[ -n "$EXTERNAL_IP" ]]; then
  echo "External IP: $EXTERNAL_IP"
  echo "Test: curl http://$EXTERNAL_IP/health"
  echo "List: curl http://$EXTERNAL_IP/list"
  echo "Upload: curl http://$EXTERNAL_IP/upload"
else
  echo "External IP pending. Check: kubectl get service $SERVICE_NAME -n $SERVICE_ACCOUNT_NAMESPACE"
fi

echo "Append outputs to env file..."
{
  echo ""; echo "# Lab 5 outputs - Service Principal app deployment";
  echo "LAB5_DEPLOYMENT_NAME=$DEPLOYMENT_NAME";
  echo "LAB5_SERVICE_NAME=$SERVICE_NAME";
  echo "LAB5_NAMESPACE=$SERVICE_ACCOUNT_NAMESPACE";
  [[ -n "$EXTERNAL_IP" ]] && echo "LAB5_EXTERNAL_IP=$EXTERNAL_IP";
} >> "$LAB_ENV"
echo "Outputs appended to $LAB_ENV"

rm -f /tmp/lab5-deployment.yaml /tmp/lab5-service.yaml
echo "Done."
echo ""
echo "View pods:"
echo "  kubectl get pods -l app=aks-storage-app-sp"
echo ""

# Append Lab 5 application outputs to the shared env file (repo root)
# Remove old Lab 5 app outputs if they exist (more robust cleanup)
grep -v "^# Lab 5 app outputs" "$LAB_ENV" | grep -v "^SP_CONTAINER_NAME=" | grep -v "^SP_APP_IMAGE=" | grep -v "^SP_APP_DEPLOYMENT_NAME=" | grep -v "^SP_APP_SERVICE_NAME=" | grep -v "^SP_APP_NAMESPACE=" | grep -v "^SP_APP_EXTERNAL_IP=" > "$LAB_ENV.tmp" && mv "$LAB_ENV.tmp" "$LAB_ENV"

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
