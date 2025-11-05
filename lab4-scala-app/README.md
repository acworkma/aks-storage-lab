# Lab 4: Scala Application with Azure Storage and Workload Identity

This lab demonstrates how to build and deploy a **Scala 3** application using **Akka HTTP** that securely accesses Azure Storage using **AKS Workload Identity**.

## Overview

- **Language**: Scala 3.3.1
- **Build Tool**: sbt 1.9.7
- **Web Framework**: Akka HTTP 10.5.3
- **Azure SDK**: Java Azure SDK (azure-storage-blob, azure-identity)
- **Container Runtime**: Microsoft OpenJDK 21

## Prerequisites

- Completed Lab 1 (AKS cluster + Storage Account)
- Completed Lab 2 (Workload Identity configuration)
- Docker installed
- sbt installed (optional, for local development)

## Application Features

### Endpoints

- `GET /` - Home page with app information
- `GET /health` - Health check with storage connectivity test
- `GET /list` - List all blobs in the container
- `POST /upload` - Upload a test file to demonstrate write access

### Architecture

The application uses:
- **DefaultAzureCredential** for authentication (automatically uses workload identity in AKS)
- **BlobServiceClient** from Azure SDK to interact with blob storage
- **Akka HTTP** for REST API server
- **Spray JSON** for JSON serialization

## Project Structure

```
lab4-scala-app/
├── build.sbt                 # sbt build configuration
├── project/
│   ├── build.properties      # sbt version
│   └── plugins.sbt           # sbt plugins (assembly)
├── src/
│   └── main/
│       └── scala/
│           └── com/azure/aksstorage/
│               └── Main.scala    # Main application code
├── k8s/
│   ├── deployment.yaml       # Kubernetes deployment
│   └── service.yaml          # LoadBalancer service
├── Dockerfile                # Multi-stage Docker build
└── deploy-app.sh             # Deployment script
```

## Build the Application

### Option 1: Build Docker Image (Recommended)

The deploy script will automatically build the Docker image if not present:

```bash
bash deploy-app.sh
```

### Option 2: Manual Docker Build

```bash
cd lab4-scala-app
docker build -t aks-storage-app-scala:latest .
```

The multi-stage Dockerfile:
1. **Stage 1 (Builder)**: Uses `sbtscala/scala-sbt` image to compile and create fat JAR via `sbt assembly`
2. **Stage 2 (Runtime)**: Uses `mcr.microsoft.com/openjdk/jdk:21-mariner` for a minimal runtime image

Build time: ~5-10 minutes (first build downloads dependencies and compiles)

### Option 3: Local Development Build

```bash
cd lab4-scala-app
sbt compile          # Compile only
sbt assembly         # Create fat JAR at target/scala-3.3.1/aks-storage-app.jar
sbt run              # Run locally (requires AZURE_STORAGE_ACCOUNT_NAME env var)
```

## Deploy to AKS

### Automatic Deployment

Run the deployment script from the repository root:

```bash
bash lab4-scala-app/deploy-app.sh
```

The script will:
1. Source environment variables from `lab-outputs.env`
2. Check if Docker image exists (build if needed)
3. Update Kubernetes manifests with storage account name
4. Deploy to AKS with workload identity
5. Wait for external IP assignment
6. Append Lab 4 outputs to `lab-outputs.env`

### Manual Deployment

```bash
# Build image
docker build -t aks-storage-app-scala:latest lab4-scala-app/

# Update deployment.yaml with your storage account name
sed -e "s/<your-storage-account-name>/$STORAGE_ACCOUNT_NAME/g" \
    lab4-scala-app/k8s/deployment.yaml > /tmp/deployment-temp.yaml

# Deploy
kubectl apply -f /tmp/deployment-temp.yaml
kubectl apply -f lab4-scala-app/k8s/service.yaml

# Wait for deployment
kubectl rollout status deployment/aks-storage-app-scala
```

## Test the Application

Once deployed, get the external IP:

```bash
kubectl get service aks-storage-app-scala-service
```

Test endpoints:

```bash
# Home page
curl http://<EXTERNAL-IP>/

# Health check
curl http://<EXTERNAL-IP>/health

# List blobs
curl http://<EXTERNAL-IP>/list

# Upload test file
curl -X POST http://<EXTERNAL-IP>/upload
```

## Verify Workload Identity

Check that Azure environment variables are injected:

```bash
POD=$(kubectl get pod -l app=aks-storage-app-scala -o jsonpath='{.items[0].metadata.name}')
kubectl exec $POD -- env | grep AZURE
```

You should see:
- `AZURE_CLIENT_ID` - Managed identity client ID
- `AZURE_TENANT_ID` - Azure tenant ID
- `AZURE_FEDERATED_TOKEN_FILE` - Path to projected service account token

## View Logs

```bash
kubectl logs -l app=aks-storage-app-scala --tail=50 -f
```

## Troubleshooting

### Build Issues

**Problem**: sbt dependency resolution fails
```bash
# Clear ivy cache and rebuild
rm -rf ~/.ivy2/cache
sbt clean
sbt assembly
```

**Problem**: Out of memory during build
```bash
# Increase Docker build memory or use export SBT_OPTS
export SBT_OPTS="-Xmx2G"
```

### Deployment Issues

**Problem**: Pods stuck in `ImagePullBackOff`
```bash
# Verify image exists locally
docker images | grep aks-storage-app-scala

# For ACR deployment, ensure image is pushed:
# docker tag aks-storage-app-scala:latest <acr-name>.azurecr.io/aks-storage-app-scala:v1
# docker push <acr-name>.azurecr.io/aks-storage-app-scala:v1
```

**Problem**: Pods crash with authentication errors
```bash
# Verify workload identity is configured
kubectl describe pod -l app=aks-storage-app-scala | grep -A5 "azure.workload.identity"
kubectl get serviceaccount workload-identity-sa -o yaml
```

### Akka-specific Issues

**Problem**: Akka HTTP binding failures
- Check port 8080 is not already in use
- Verify readiness/liveness probe paths match routes
- Check resource limits (Akka requires more memory than simple apps)

## Comparison: Scala vs Python

| Aspect | Scala (Lab 4) | Python (Lab 3) |
|--------|---------------|----------------|
| **Startup Time** | ~15-20s (JVM warmup) | ~2-5s (inline) / ~5-10s (container) |
| **Memory Usage** | 512Mi-1Gi | 128Mi-512Mi |
| **Build Time** | 5-10 min (first build) | Instant (inline) / 1-2 min (Docker) |
| **Type Safety** | Compile-time | Runtime |
| **Concurrency** | Akka actor model | asyncio / threading |
| **Image Size** | ~400-500MB | ~200-300MB |
| **Performance** | High throughput | Good for I/O |

## Production Considerations

### Container Registry

For production, push to Azure Container Registry:

```bash
ACR_NAME="<your-acr-name>"
az acr login --name $ACR_NAME

docker tag aks-storage-app-scala:latest $ACR_NAME.azurecr.io/aks-storage-app-scala:v1
docker push $ACR_NAME.azurecr.io/aks-storage-app-scala:v1

# Update deployment.yaml image reference
# image: <your-acr-name>.azurecr.io/aks-storage-app-scala:v1
```

### JVM Tuning

The Dockerfile includes container-aware JVM flags:
- `-XX:+UseContainerSupport` - Respect container memory limits
- `-XX:MaxRAMPercentage=75.0` - Use up to 75% of container memory

For production, tune based on workload:
```dockerfile
ENV JAVA_OPTS="-XX:+UseG1GC -XX:MaxGCPauseMillis=200 -XX:+HeapDumpOnOutOfMemoryError"
```

### Resource Limits

Adjust based on load:
```yaml
resources:
  requests:
    cpu: 500m
    memory: 1Gi
  limits:
    cpu: 2000m
    memory: 2Gi
```

## Clean Up

To remove the Scala application deployment:

```bash
kubectl delete -f lab4-scala-app/k8s/deployment.yaml
kubectl delete -f lab4-scala-app/k8s/service.yaml
```

## Next Steps

- Compare Scala vs Python performance under load
- Add metrics/monitoring (Prometheus, Azure Monitor)
- Implement caching layer (Redis)
- Add integration tests with Akka HTTP TestKit
- Explore GraalVM native-image for faster startup

## References

- [Scala Documentation](https://docs.scala-lang.org/scala3/)
- [Akka HTTP Documentation](https://doc.akka.io/docs/akka-http/current/)
- [Azure SDK for Java](https://learn.microsoft.com/en-us/azure/developer/java/sdk/)
- [sbt Documentation](https://www.scala-sbt.org/1.x/docs/)
