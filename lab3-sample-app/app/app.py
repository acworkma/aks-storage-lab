"""
AKS Storage Lab - Sample Application

This Flask application demonstrates secure access to Azure Storage
using workload identity (managed identity) from AKS.
"""

from flask import Flask, jsonify, render_template_string
from azure.identity import DefaultAzureCredential
from azure.storage.blob import BlobServiceClient, BlobClient
from datetime import datetime
import os
import logging

# Configure logging
logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

app = Flask(__name__)

# Get configuration from environment variables
STORAGE_ACCOUNT_NAME = os.getenv('AZURE_STORAGE_ACCOUNT_NAME')
CONTAINER_NAME = os.getenv('AZURE_STORAGE_CONTAINER_NAME', 'data')

# Validate configuration
if not STORAGE_ACCOUNT_NAME:
    logger.error("AZURE_STORAGE_ACCOUNT_NAME environment variable is not set")
    raise ValueError("AZURE_STORAGE_ACCOUNT_NAME must be set")

# Initialize Azure Storage client with DefaultAzureCredential
# This automatically uses workload identity when running in AKS
account_url = f"https://{STORAGE_ACCOUNT_NAME}.blob.core.windows.net"
logger.info(f"Initializing BlobServiceClient for {account_url}")

try:
    credential = DefaultAzureCredential()
    blob_service_client = BlobServiceClient(account_url, credential=credential)
    logger.info("BlobServiceClient initialized successfully")
except Exception as e:
    logger.error(f"Failed to initialize BlobServiceClient: {str(e)}")
    raise

# HTML template for the home page
HOME_TEMPLATE = """
<!DOCTYPE html>
<html>
<head>
    <title>AKS Storage Lab - Sample App</title>
    <style>
        body {
            font-family: Arial, sans-serif;
            max-width: 800px;
            margin: 50px auto;
            padding: 20px;
            background-color: #f5f5f5;
        }
        .container {
            background-color: white;
            padding: 30px;
            border-radius: 8px;
            box-shadow: 0 2px 4px rgba(0,0,0,0.1);
        }
        h1 {
            color: #0078d4;
        }
        .info {
            background-color: #e7f3ff;
            padding: 15px;
            border-radius: 4px;
            margin: 20px 0;
        }
        .endpoint {
            background-color: #f0f0f0;
            padding: 10px;
            margin: 10px 0;
            border-radius: 4px;
            font-family: monospace;
        }
        .success {
            color: #107c10;
            font-weight: bold;
        }
        button {
            background-color: #0078d4;
            color: white;
            border: none;
            padding: 10px 20px;
            margin: 5px;
            border-radius: 4px;
            cursor: pointer;
        }
        button:hover {
            background-color: #005a9e;
        }
        .result {
            margin-top: 20px;
            padding: 15px;
            background-color: #f9f9f9;
            border: 1px solid #ddd;
            border-radius: 4px;
            white-space: pre-wrap;
            font-family: monospace;
            font-size: 12px;
        }
    </style>
</head>
<body>
    <div class="container">
        <h1>🚀 AKS Storage Lab - Sample Application</h1>
        
        <div class="info">
            <p><strong>Storage Account:</strong> {{ storage_account }}</p>
            <p><strong>Container:</strong> {{ container_name }}</p>
            <p><strong>Authentication:</strong> <span class="success">Workload Identity (Managed Identity)</span></p>
        </div>

        <h2>Available Endpoints:</h2>
        
        <div class="endpoint">
            <strong>GET /health</strong> - Health check endpoint
        </div>
        
        <div class="endpoint">
            <strong>GET /list</strong> - List all blobs in the container
        </div>
        
        <div class="endpoint">
            <strong>POST /upload</strong> - Upload a test file to the container
        </div>

        <h2>Quick Actions:</h2>
        <button onclick="checkHealth()">Check Health</button>
        <button onclick="listBlobs()">List Blobs</button>
        <button onclick="uploadTest()">Upload Test File</button>

        <div id="result" class="result" style="display:none;"></div>
    </div>

    <script>
        function showResult(data) {
            const resultDiv = document.getElementById('result');
            resultDiv.textContent = JSON.stringify(data, null, 2);
            resultDiv.style.display = 'block';
        }

        function checkHealth() {
            fetch('/health')
                .then(response => response.json())
                .then(data => showResult(data))
                .catch(error => showResult({error: error.message}));
        }

        function listBlobs() {
            fetch('/list')
                .then(response => response.json())
                .then(data => showResult(data))
                .catch(error => showResult({error: error.message}));
        }

        function uploadTest() {
            fetch('/upload', {method: 'POST'})
                .then(response => response.json())
                .then(data => showResult(data))
                .catch(error => showResult({error: error.message}));
        }
    </script>
</body>
</html>
"""

@app.route('/')
def home():
    """Home page with information about the application"""
    return render_template_string(
        HOME_TEMPLATE,
        storage_account=STORAGE_ACCOUNT_NAME,
        container_name=CONTAINER_NAME
    )

@app.route('/health')
def health():
    """Health check endpoint"""
    try:
        # Try to get container properties to verify connectivity
        container_client = blob_service_client.get_container_client(CONTAINER_NAME)
        container_client.get_container_properties()
        
        return jsonify({
            'status': 'healthy',
            'storage_account': STORAGE_ACCOUNT_NAME,
            'container': CONTAINER_NAME,
            'authentication': 'workload_identity',
            'timestamp': datetime.utcnow().isoformat()
        })
    except Exception as e:
        logger.error(f"Health check failed: {str(e)}")
        return jsonify({
            'status': 'unhealthy',
            'error': str(e),
            'timestamp': datetime.utcnow().isoformat()
        }), 500

@app.route('/list')
def list_blobs():
    """List all blobs in the container"""
    try:
        container_client = blob_service_client.get_container_client(CONTAINER_NAME)
        blobs = []
        
        for blob in container_client.list_blobs():
            blobs.append({
                'name': blob.name,
                'size': blob.size,
                'last_modified': blob.last_modified.isoformat() if blob.last_modified else None,
                'content_type': blob.content_settings.content_type if blob.content_settings else None
            })
        
        logger.info(f"Listed {len(blobs)} blobs from container {CONTAINER_NAME}")
        
        return jsonify({
            'container': CONTAINER_NAME,
            'blob_count': len(blobs),
            'blobs': blobs,
            'timestamp': datetime.utcnow().isoformat()
        })
    except Exception as e:
        logger.error(f"Failed to list blobs: {str(e)}")
        return jsonify({
            'error': str(e),
            'timestamp': datetime.utcnow().isoformat()
        }), 500

@app.route('/upload', methods=['POST'])
def upload_test_file():
    """Upload a test file to demonstrate write access"""
    try:
        # Create a test file content
        timestamp = datetime.utcnow().isoformat()
        blob_name = f"test-file-{timestamp}.txt"
        content = f"Test file created at {timestamp}\nThis file was uploaded using workload identity!\n"
        
        # Upload the blob
        blob_client = blob_service_client.get_blob_client(
            container=CONTAINER_NAME,
            blob=blob_name
        )
        blob_client.upload_blob(content, overwrite=True)
        
        logger.info(f"Successfully uploaded blob: {blob_name}")
        
        return jsonify({
            'status': 'success',
            'blob_name': blob_name,
            'container': CONTAINER_NAME,
            'size': len(content),
            'message': 'File uploaded successfully using managed identity',
            'timestamp': timestamp
        })
    except Exception as e:
        logger.error(f"Failed to upload blob: {str(e)}")
        return jsonify({
            'status': 'error',
            'error': str(e),
            'timestamp': datetime.utcnow().isoformat()
        }), 500

if __name__ == '__main__':
    logger.info("Starting AKS Storage Lab application")
    logger.info(f"Storage Account: {STORAGE_ACCOUNT_NAME}")
    logger.info(f"Container: {CONTAINER_NAME}")
    
    # Run the Flask app
    app.run(host='0.0.0.0', port=8080, debug=False)
