# Building and Pushing the Container Image

This guide explains how to build and push the sample application container image.

## Option 1: Use the Inline Image (Quickstart)

The provided `deployment.yaml` includes an inline Python application that runs directly. This is perfect for quick testing and learning without needing to build and push a container image.

**Pros:**
- No build or push required
- Quick to deploy
- Good for learning and testing

**Cons:**
- Slower startup time (installs packages on pod start)
- Not recommended for production

## Option 2: Build Your Own Image

For a production-ready deployment, build the Docker image from the provided Dockerfile.

### Prerequisites

- Docker installed
- Access to a container registry (Azure Container Registry recommended)

### Using Azure Container Registry (ACR)

1. **Create an ACR (if you don't have one):**

```bash
ACR_NAME="myacr$RANDOM"
az acr create \
  --resource-group rg-aks-storage-lab \
  --name $ACR_NAME \
  --sku Basic
```

2. **Attach ACR to AKS (for image pull):**

```bash
az aks update \
  --resource-group rg-aks-storage-lab \
  --name aks-storage-cluster \
  --attach-acr $ACR_NAME
```

3. **Login to ACR:**

```bash
az acr login --name $ACR_NAME
```

4. **Build and push the image:**

```bash
cd app/

# Build the image
docker build -t ${ACR_NAME}.azurecr.io/aks-storage-app:v1 .

# Push to ACR
docker push ${ACR_NAME}.azurecr.io/aks-storage-app:v1
```

5. **Update deployment.yaml:**

Edit `k8s/deployment.yaml` and replace the image section:

```yaml
image: <your-acr-name>.azurecr.io/aks-storage-app:v1
imagePullPolicy: Always
```

Remove or comment out the `command:` section.

6. **Deploy:**

```bash
kubectl apply -f k8s/deployment.yaml
kubectl apply -f k8s/service.yaml
```

### Using Docker Hub

1. **Login to Docker Hub:**

```bash
docker login
```

2. **Build and push:**

```bash
cd app/

# Build (replace 'yourusername' with your Docker Hub username)
docker build -t yourusername/aks-storage-app:v1 .

# Push
docker push yourusername/aks-storage-app:v1
```

3. **Update deployment.yaml:**

```yaml
image: yourusername/aks-storage-app:v1
imagePullPolicy: Always
```

### Using GitHub Container Registry (GHCR)

1. **Create a GitHub Personal Access Token** with `write:packages` scope

2. **Login to GHCR:**

```bash
echo $GITHUB_TOKEN | docker login ghcr.io -u USERNAME --password-stdin
```

3. **Build and push:**

```bash
cd app/

docker build -t ghcr.io/yourusername/aks-storage-app:v1 .
docker push ghcr.io/yourusername/aks-storage-app:v1
```

## Testing Locally

Before deploying to AKS, you can test the image locally:

```bash
cd app/

# Build
docker build -t aks-storage-app:test .

# Run (requires Azure credentials)
docker run -p 8080:8080 \
  -e AZURE_STORAGE_ACCOUNT_NAME=yourstorageaccount \
  -e AZURE_STORAGE_CONTAINER_NAME=data \
  aks-storage-app:test
```

**Note:** Running locally requires Azure authentication. The DefaultAzureCredential will try various methods including Azure CLI credentials.

## Troubleshooting

**Issue:** Image push fails with authentication error
- **Solution:** Ensure you're logged in to your registry

**Issue:** AKS cannot pull the image
- **Solution:** For ACR, ensure it's attached to AKS. For other registries, create an image pull secret

**Issue:** Different architecture (ARM vs x64)
- **Solution:** Build for the correct platform:
  ```bash
  docker buildx build --platform linux/amd64 -t yourimage:v1 .
  ```
