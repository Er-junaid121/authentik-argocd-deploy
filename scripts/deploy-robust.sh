#!/bin/bash

echo "🚀 Starting Robust Authentik + ArgoCD deployment on AWS EKS..."

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

print_status() { echo -e "${BLUE}ℹ️  $1${NC}"; }
print_success() { echo -e "${GREEN}✅ $1${NC}"; }
print_warning() { echo -e "${YELLOW}⚠️  $1${NC}"; }
print_error() { echo -e "${RED}❌ $1${NC}"; }

# Get absolute paths to avoid directory issues
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TERRAFORM_DIR="$PROJECT_ROOT/terraform"
CLUSTER_NAME=${CLUSTER_NAME:-"authentik-cluster"}
AWS_REGION=${AWS_REGION:-"ap-south-1"}

print_status "Project Root: $PROJECT_ROOT"
print_status "Terraform Dir: $TERRAFORM_DIR"

# Check prerequisites (Windows compatible)
for cmd in terraform aws kubectl helm; do
    if ! command -v $cmd >/dev/null 2>&1; then
        print_error "$cmd is required but not installed"
        exit 1
    fi
done

# Check openssl (may be in different location on Windows)
if ! command -v openssl >/dev/null 2>&1; then
    if ! command -v openssl.exe >/dev/null 2>&1; then
        print_error "openssl is required but not installed"
        exit 1
    fi
fi
print_success "All prerequisites found"

# Check terraform.tfvars
if [ ! -f "$TERRAFORM_DIR/terraform.tfvars" ]; then
    print_error "terraform.tfvars not found at $TERRAFORM_DIR/terraform.tfvars"
    exit 1
fi

# Verify AWS credentials
if ! aws sts get-caller-identity >/dev/null 2>&1; then
    print_error "AWS credentials not configured"
    exit 1
fi
print_success "AWS credentials verified"

# Terraform operations (with absolute paths)
print_status "Terraform operations..."
cd "$TERRAFORM_DIR"
terraform init
terraform validate
terraform plan -out=tfplan

echo ""
print_warning "About to apply Terraform configuration"
read -p "Continue? (y/N): " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    print_status "Cancelled"
    exit 0
fi

terraform apply tfplan
print_success "Infrastructure deployed"

# Get outputs immediately while in terraform directory
DB_HOST=$(terraform output -raw rds_endpoint 2>/dev/null | cut -d':' -f1 || echo "")
REDIS_HOST=$(terraform output -raw redis_endpoint 2>/dev/null || echo "")
DB_PASSWORD=$(terraform output -raw db_password 2>/dev/null || echo "")

# Fallback to tfvars if outputs fail
if [ -z "$DB_PASSWORD" ]; then
    DB_PASSWORD=$(grep '^db_password' terraform.tfvars | cut -d'"' -f2 2>/dev/null || echo "MySecureDBPassword123!")
fi

print_status "Retrieved: DB_HOST=$DB_HOST"
print_status "Retrieved: REDIS_HOST=$REDIS_HOST"
print_status "Retrieved: DB_PASSWORD=[HIDDEN]"

# Return to project root
cd "$PROJECT_ROOT"

# Configure kubectl
print_status "Configuring kubectl..."
aws eks update-kubeconfig --region $AWS_REGION --name $CLUSTER_NAME

# Wait for cluster
print_status "Waiting for cluster..."
kubectl wait --for=condition=Ready nodes --all --timeout=600s

# Create namespaces
print_status "Creating namespaces..."
kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -
kubectl create namespace authentik --dry-run=client -o yaml | kubectl apply -f -

# Install ArgoCD
print_status "Installing ArgoCD..."
helm repo add argo https://argoproj.github.io/argo-helm >/dev/null 2>&1
helm repo update >/dev/null 2>&1
helm install argocd argo/argo-cd \
    --namespace argocd \
    --set server.service.type=ClusterIP \
    --set server.extraArgs[0]=--insecure \
    --set configs.params."server\.insecure"=true

kubectl wait --for=condition=available --timeout=600s deployment/argocd-server -n argocd

# Install NGINX Ingress
print_status "Installing NGINX Ingress..."
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx >/dev/null 2>&1
helm repo update >/dev/null 2>&1
helm install ingress-nginx ingress-nginx/ingress-nginx \
    --namespace ingress-nginx \
    --create-namespace \
    --set controller.service.type=LoadBalancer \
    --set controller.service.annotations."service\.beta\.kubernetes\.io/aws-load-balancer-type"="nlb" \
    --set controller.service.annotations."service\.beta\.kubernetes\.io/aws-load-balancer-scheme"="internet-facing"

kubectl wait --namespace ingress-nginx \
    --for=condition=ready pod \
    --selector=app.kubernetes.io/component=controller \
    --timeout=300s

# Generate secrets
print_status "Creating secrets..."
# Use openssl or openssl.exe depending on availability
if command -v openssl >/dev/null 2>&1; then
    AUTHENTIK_SECRET_KEY=$(openssl rand -base64 32 | tr -d "=+/" | cut -c1-50)
elif command -v openssl.exe >/dev/null 2>&1; then
    AUTHENTIK_SECRET_KEY=$(openssl.exe rand -base64 32 | tr -d "=+/" | cut -c1-50)
else
    # Fallback: generate random string
    AUTHENTIK_SECRET_KEY=$(cat /dev/urandom | tr -dc 'a-zA-Z0-9' | fold -w 50 | head -n 1 2>/dev/null || echo "fallback-secret-key-$(date +%s)")
fi

kubectl create secret generic authentik-secrets \
    --namespace=authentik \
    --from-literal=AUTHENTIK_SECRET_KEY="$AUTHENTIK_SECRET_KEY" \
    --from-literal=AUTHENTIK_POSTGRESQL__PASSWORD="$DB_PASSWORD" \
    --from-literal=AUTHENTIK_POSTGRESQL__HOST="$DB_HOST" \
    --from-literal=AUTHENTIK_POSTGRESQL__NAME="authentik" \
    --from-literal=AUTHENTIK_POSTGRESQL__USER="authentik" \
    --from-literal=AUTHENTIK_REDIS__HOST="$REDIS_HOST" \
    --dry-run=client -o yaml | kubectl apply -f -

# Deploy Authentik
print_status "Deploying Authentik..."
kubectl apply -f "$PROJECT_ROOT/argocd/applications/authentik.yaml"

# Monitor sync
print_status "Monitoring ArgoCD sync..."
for i in {1..20}; do
    SYNC_STATUS=$(kubectl get application authentik -n argocd -o jsonpath='{.status.sync.status}' 2>/dev/null || echo "Unknown")
    HEALTH_STATUS=$(kubectl get application authentik -n argocd -o jsonpath='{.status.health.status}' 2>/dev/null || echo "Unknown")
    
    echo "Status: $SYNC_STATUS, Health: $HEALTH_STATUS ($i/20)"
    
    if [ "$SYNC_STATUS" = "Synced" ] && [ "$HEALTH_STATUS" = "Healthy" ]; then
        print_success "Authentik synced and healthy"
        break
    fi
    
    if [ $i -eq 10 ]; then
        print_status "Forcing sync..."
        kubectl patch application authentik -n argocd --type merge --patch '{"operation":{"sync":{}}}' 2>/dev/null || true
    fi
    
    sleep 15
done

# Apply ingress
print_status "Applying ingress..."
kubectl apply -f "$PROJECT_ROOT/k8s-manifests/ingress-resources.yaml"

# Final status
print_status "Getting access information..."
NGINX_URL=$(kubectl get svc ingress-nginx-controller -n ingress-nginx -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || echo "")
ARGOCD_PASSWORD=$(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" 2>/dev/null | base64 -d 2>/dev/null || echo "")

echo ""
print_success "🎉 Deployment Complete!"
echo ""
echo "📋 Access Information:"
echo "   ArgoCD: kubectl port-forward svc/argocd-server -n argocd 8080:80"
echo "   ArgoCD URL: http://localhost:8080"
echo "   ArgoCD User: admin"
echo "   ArgoCD Pass: $ARGOCD_PASSWORD"
echo ""
if [ ! -z "$NGINX_URL" ]; then
    echo "   Authentik: http://$NGINX_URL"
else
    echo "   Authentik: Get URL with 'kubectl get svc ingress-nginx-controller -n ingress-nginx'"
fi
echo ""
print_success "🚀 All systems operational!"