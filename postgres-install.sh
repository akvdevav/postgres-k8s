#!/bin/bash

# ==========================================
# 1. LOAD CONFIGURATION FROM .env
# ==========================================
ENV_FILE=".env"
INSTANCE_YAML="postgres-instance.yaml"

if [ -f "$ENV_FILE" ]; then
    echo "Loading credentials from $ENV_FILE..."
    export $(grep -v '^#' "$ENV_FILE" | xargs)
else
    echo "❌ Error: $ENV_FILE file not found!"
    exit 1
fi

if [ ! -f "$INSTANCE_YAML" ]; then
    echo "❌ Error: $INSTANCE_YAML file not found!"
    exit 1
fi

if [ -z "$REGISTRY_USER" ] || [ -z "$REGISTRY_PASS" ]; then
    echo "❌ Error: REGISTRY_USER or REGISTRY_PASS is empty in the .env file!"
    exit 1
fi

# Namespaces & Operator Version
OPERATOR_NAMESPACE="default"
INSTANCE_NAMESPACE="wp-demo"
OPERATOR_VERSION="v3.0.0"

# ==========================================
# 2. CHECK AND INSTALL CERT-MANAGER
# ==========================================
echo "Checking for Cert-Manager..."
if kubectl get deployment -n cert-manager cert-manager >/dev/null 2>&1; then
    echo "✅ Cert-Manager is already installed. Skipping deployment."
else
    echo "⚠️ Cert-Manager not found. Installing..."
    helm repo add jetstack https://charts.jetstack.io --force-update
    helm install cert-manager jetstack/cert-manager \
        --namespace cert-manager \
        --create-namespace \
        --version v1.12.0 \
        --set installCRDs=true \
        --wait
    echo "✅ Cert-Manager installed successfully."
fi

# ==========================================
# 3. PREPARE NAMESPACES & SECRETS
# ==========================================
echo "Setting up namespaces and Docker registry secrets..."
kubectl create namespace $OPERATOR_NAMESPACE --dry-run=client -o yaml | kubectl apply -f -
kubectl create namespace $INSTANCE_NAMESPACE --dry-run=client -o yaml | kubectl apply -f -

# Operator Namespace Secret
kubectl create secret docker-registry regsecret \
    --namespace $OPERATOR_NAMESPACE \
    --docker-server=https://tanzu-sql-postgres.packages.broadcom.com/ \
    --docker-username="$REGISTRY_USER" \
    --docker-password="$REGISTRY_PASS" \
    --dry-run=client -o yaml | kubectl apply -f -

# Instance Namespace Secret
kubectl create secret docker-registry regsecret \
    --namespace $INSTANCE_NAMESPACE \
    --docker-server=https://tanzu-sql-postgres.packages.broadcom.com/ \
    --docker-username="$REGISTRY_USER" \
    --docker-password="$REGISTRY_PASS" \
    --dry-run=client -o yaml | kubectl apply -f -

# ==========================================
# 4. DEPLOY TANZU POSTGRES OPERATOR
# ==========================================
echo "Authenticating Helm to Broadcom Registry..."
export HELM_EXPERIMENTAL_OCI=1
echo "$REGISTRY_PASS" | helm registry login tanzu-sql-postgres.packages.broadcom.com --username "$REGISTRY_USER" --password-stdin

echo "Deploying Tanzu Postgres Operator ($OPERATOR_VERSION)..."
helm upgrade --install my-postgres-operator \
    oci://tanzu-sql-postgres.packages.broadcom.com/vmware-sql-postgres-operator \
    --version $OPERATOR_VERSION \
    --namespace $OPERATOR_NAMESPACE \
    --wait

echo "✅ Postgres Operator deployed successfully."

# ==========================================
# 5. DEPLOY POSTGRES INSTANCE
# ==========================================
echo "Deploying Postgres Instance from $INSTANCE_YAML..."
kubectl apply -f $INSTANCE_YAML

echo "=========================================="
echo "🎉 Deployment initiated successfully!"
echo "To monitor the deployment progress, run:"
echo "watch kubectl get pods,pvc -n $INSTANCE_NAMESPACE"
echo "=========================================="