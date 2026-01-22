# Lab 4: Scala Application with Azure Storage and AKS Workload Identity

This lab builds and deploys a **Scala 3** application using **Akka HTTP** that securely accesses Azure Blob Storage via **AKS Workload Identity**.

## Overview

- **Language**: Scala 3.3.1
- **Build Tool**: sbt 1.9.7
- **Web Framework**: Akka HTTP 10.5.3
- **Azure SDK**: Java Azure SDK (azure-storage-blob, azure-identity)
- **Container Runtime**: Microsoft OpenJDK 21
- **Auth**: `DefaultAzureCredential` (Managed Identity in AKS)

## Prerequisites

- Completed Lab 1 (AKS cluster, Storage Account, ACR)
- Completed Lab 2 (Workload Identity configuration)
- Docker installed
- Azure CLI logged in (`az login`)
- sbt installed (optional for local development)

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
│   ├── deployment.yaml       # Kubernetes deployment (namespace: lab4)
│   └── service.yaml          # LoadBalancer service (namespace: lab4)
├── Dockerfile                # Multi-stage Docker build
└── deploy-app.sh             # Deployment script
```
## Build the Application

You can rely entirely on the deployment script for image build + ACR push. Manual options are still available for advanced scenarios.

### Option 1 (Recommended): Automatic Build via Deploy Script

```bash
bash lab4-scala-app/deploy-app.sh
```
What happens:
1. sbt compiles sources and produces a fat JAR via `sbt assembly`.
2. Multi-stage Docker build assembles the runtime image.
3. The image is tagged and pushed to ACR (from Lab 1).
4. Application is deployed to the `lab4` namespace.

### Option 2: Manual Docker Build

```bash
cd lab4-scala-app
docker build -t aks-storage-app-scala:latest .
```

Multi-stage Dockerfile:
1. **Builder**: `sbtscala/scala-sbt` compiles + assembles JAR.
2. **Runtime**: `mcr.microsoft.com/openjdk/jdk:21-mariner` (OpenJDK 21).

First build time: ~5–10 min (dependency resolution + compilation). Subsequent builds are much faster due to layer caching.

### Option 3: Local Development (No Containers)

```bash
cd lab4-scala-app
sbt compile
sbt run   # Requires AZURE_STORAGE_ACCOUNT_NAME + optional AZURE_STORAGE_CONTAINER_NAME
```

## Deploy to AKS

### Automatic Deployment

```bash
bash lab4-scala-app/deploy-app.sh
```

Script workflow:
1. Source env from `lab-outputs.env` (Labs 1–2 outputs).
2. Build Docker image (sbt compilation + assembly).
3. Login to ACR and push image.
4. Attach ACR to AKS for pull permissions.
5. Substitute manifest values (service account, storage account, container name, image ref).
6. Deploy to `lab4` namespace + wait for rollout.
7. Wait for LoadBalancer external IP.
8. Append outputs to `lab-outputs.env`.

Environment overrides:
| Variable | Purpose | Default |
|----------|---------|---------|
| `SCALA_APP_IMAGE_TAG` | Image tag | `latest` |
| `CONTAINER_NAME` | Blob container name | `data` |

To deploy with a custom tag:
```bash
export SCALA_APP_IMAGE_TAG=v2
bash lab4-scala-app/deploy-app.sh
```

### Manual Deployment (Advanced)

Use this if you want full manual control (CI/CD pipelines, custom images):

```bash
# Source environment
source lab-outputs.env

# Build and push
docker build -t aks-storage-app-scala:latest lab4-scala-app/
az acr login -n $ACR_NAME
docker tag aks-storage-app-scala:latest $ACR_LOGIN_SERVER/aks-storage-app-scala:manual
docker push $ACR_LOGIN_SERVER/aks-storage-app-scala:manual

# Deploy
sed -e "s/<your-storage-account-name>/$STORAGE_ACCOUNT_NAME/g" \
    -e "s/<your-container-name>/$CONTAINER_NAME/g" \
    -e "s|image: aks-storage-app-scala:latest|image: $ACR_LOGIN_SERVER/aks-storage-app-scala:manual|g" \
    -e "s/imagePullPolicy: Never/imagePullPolicy: Always/g" \
    lab4-scala-app/k8s/deployment.yaml | kubectl apply -f -

kubectl apply -f lab4-scala-app/k8s/service.yaml
kubectl rollout status deployment/aks-storage-app-scala -n lab4 --timeout=300s
```

## Test the Application

Once deployed, get the external IP:

```bash
kubectl get service aks-storage-app-scala-service -n lab4
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
POD=$(kubectl get pod -l app=aks-storage-app-scala -n lab4 -o jsonpath='{.items[0].metadata.name}')
kubectl exec $POD -n lab4 -- env | grep AZURE
```

You should see:
- `AZURE_CLIENT_ID` - Managed identity client ID
- `AZURE_TENANT_ID` - Azure tenant ID
- `AZURE_FEDERATED_TOKEN_FILE` - Path to projected service account token

## View Logs

```bash
kubectl logs -l app=aks-storage-app-scala -n lab4 --tail=50 -f
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

```bash
docker images | grep aks-storage-app-scala
```
### Deployment Issues

**Problem**: Pods stuck in `ImagePullBackOff`
```bash
kubectl describe pod <pod-name> -n lab4 | grep -i backoff
```
Cause: Image reference points to ACR but permissions not attached or image not pushed.
Fix:
```bash
bash lab4-scala-app/deploy-app.sh              # Re-run
# OR manual:
az acr login -n $ACR_NAME
docker push $ACR_LOGIN_SERVER/aks-storage-app-scala:latest
az aks update -n $AKS_CLUSTER_NAME -g $RESOURCE_GROUP --attach-acr $ACR_NAME
```

**Problem**: `ErrImageNeverPull`
Cause: Deployment still uses `imagePullPolicy: Never` with a registry image.
Fix: Ensure deploy script has updated manifest or manually patch:
```bash
kubectl patch deployment aks-storage-app-scala -n lab4 \
  --type=strategic -p '{"spec":{"template":{"spec":{"containers":[{"name":"app","imagePullPolicy":"Always"}]}}}}'
```

**Problem**: Pods crash with authentication errors
```bash
# Verify workload identity is configured
kubectl describe pod -l app=aks-storage-app-scala -n lab4 | grep -A5 "azure.workload.identity"
kubectl get serviceaccount workload-identity-sa -n lab4 -o yaml
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

```bash
az acr login --name $ACR_NAME
docker push $ACR_LOGIN_SERVER/aks-storage-app-scala:v1
```

### Custom Image Tag

```bash
SCALA_APP_IMAGE_TAG=v3 bash lab4-scala-app/deploy-app.sh
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

Current deployment defaults (in `k8s/deployment.yaml`):
```yaml
resources:
  requests:
    cpu: 200m
    memory: 512Mi
  limits:
    cpu: 1000m
    memory: 1Gi
```
Suggested scaling example:
```yaml
resources:
  requests:
    cpu: 500m
    memory: 1Gi
  limits:
    cpu: 2000m
    memory: 2Gi
```

## Clean Up (Application Only)

```bash
kubectl delete -f lab4-scala-app/k8s/deployment.yaml
kubectl delete -f lab4-scala-app/k8s/service.yaml
```

Or delete by namespace resources:
```bash
kubectl delete deployment aks-storage-app-scala -n lab4
kubectl delete service aks-storage-app-scala-service -n lab4
```

## Quick Commands

```bash
# Redeploy with new tag
SCALA_APP_IMAGE_TAG=v2 bash lab4-scala-app/deploy-app.sh

# Check deployment status
kubectl get pods -l app=aks-storage-app-scala -n lab4

# View logs
kubectl logs -l app=aks-storage-app-scala -n lab4 --tail=50

# Get external IP
kubectl get service aks-storage-app-scala-service -n lab4
```

## Environment Outputs

After deployment, `lab-outputs.env` gains:
```
SCALA_APP_NAMESPACE=lab4
SCALA_CONTAINER_NAME=data
SCALA_APP_IMAGE=<full-acr-image>
SCALA_APP_DEPLOYMENT_NAME=aks-storage-app-scala
SCALA_APP_SERVICE_NAME=aks-storage-app-scala-service
SCALA_APP_EXTERNAL_IP=<ip-if-assigned>
```
Use these for subsequent automation or comparisons.

## Next Steps

- Compare Python vs Scala latency under load
- Add GitHub Actions workflow (CI: build & push image)
- Introduce metrics (Prometheus + custom `/metrics`)
- Add integration tests (Akka HTTP TestKit)
- Evaluate GraalVM native image for faster cold start
- Add `/metrics` endpoint (Prometheus format)

## References

- [Scala Documentation](https://docs.scala-lang.org/scala3/)
- [Akka HTTP Documentation](https://doc.akka.io/docs/akka-http/current/)
- [Azure SDK for Java](https://learn.microsoft.com/en-us/azure/developer/java/sdk/)
- [sbt Documentation](https://www.scala-sbt.org/1.x/docs/)
