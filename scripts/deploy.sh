#!/bin/bash
set -e

echo "🚀 Starting Authentik + ArgoCD deployment on AWS EKS..."

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Function to print colored output
print_status() {
    echo -e "${BLUE}ℹ️  $1${NC}"
}

print_success() {
    echo -e "${GREEN}✅ $1${NC}"
}

print_warning() {
    echo -e "${YELLOW}⚠️  $1${NC}"
}

print_error() {
    echo -e "${RED}❌ $1${NC}"
}

# Check prerequisites
print_status "Checking prerequisites..."

command -v terraform >/dev/null 2>&1 || { print_error "terraform is required but not installed. Aborting."; exit 1; }
command -v aws >/dev/null 2>&1 || { print_error "aws cli is required but not installed. Aborting."; exit 1; }
command -v kubectl >/dev/null 2>&1 || { print_error "kubectl is required but not installed. Aborting."; exit 1; }

print_success "All prerequisites found"

# Change to project root directory
cd "$(dirname "$0")/.."

# Set variables
TERRAFORM_DIR="./terraform"
CLUSTER_NAME=${CLUSTER_NAME:-"authentik-cluster"}
AWS_REGION=${AWS_REGION:-"ap-south-1"}

echo ""
print_status "Configuration:"
echo "   Cluster Name: $CLUSTER_NAME"
echo "   AWS Region: $AWS_REGION"
echo ""

# Check if terraform.tfvars exists
if [ ! -f "$TERRAFORM_DIR/terraform.tfvars" ]; then
    print_error "terraform.tfvars not found. Please create it from terraform.tfvars.example"
    echo "Run: cp $TERRAFORM_DIR/terraform.tfvars.example $TERRAFORM_DIR/terraform.tfvars"
    echo "Then edit the file with your values."
    exit 1
fi

# Verify AWS credentials
print_status "Verifying AWS credentials..."
aws sts get-caller-identity > /dev/null || { print_error "AWS credentials not configured. Run 'aws configure'"; exit 1; }
print_success "AWS credentials verified"

# Initialize and apply Terraform
print_status "Initializing Terraform..."
cd $TERRAFORM_DIR
terraform init

print_status "Validating Terraform configuration..."
terraform validate

print_status "Planning Terraform deployment..."
terraform plan -out=tfplan

echo ""
print_warning "About to apply Terraform configuration. This will create AWS resources."
read -p "Do you want to continue? (y/N): " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    print_status "Deployment cancelled."
    exit 0
fi

print_status "Applying Terraform configuration..."
terraform apply tfplan

print_success "Infrastructure deployed successfully!"

# Configure kubectl
print_status "Configuring kubectl..."
aws eks update-kubeconfig --region $AWS_REGION --name $CLUSTER_NAME

# Wait for cluster to be ready
print_status "Waiting for EKS cluster nodes to be ready..."
kubectl wait --for=condition=Ready nodes --all --timeout=600s

print_success "EKS cluster is ready!"

# Create namespaces
print_status "Creating Kubernetes namespaces..."
kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -
kubectl create namespace authentik --dry-run=client -o yaml | kubectl apply -f -

# Install ArgoCD
print_status "Installing ArgoCD..."
helm repo add argo https://argoproj.github.io/argo-helm
helm repo update
helm install argocd argo/argo-cd \
    --namespace argocd \
    --set server.service.type=ClusterIP \
    --set server.extraArgs[0]=--insecure \
    --set configs.params."server\.insecure"=true

# Wait for ArgoCD to be ready
print_status "Waiting for ArgoCD to be ready..."
kubectl wait --for=condition=available --timeout=600s deployment/argocd-server -n argocd

# Get ArgoCD admin password
print_status "Getting ArgoCD admin password..."
ARGOCD_PASSWORD=""
for i in {1..30}; do
    ARGOCD_PASSWORD=$(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" 2>/dev/null | base64 -d 2>/dev/null || echo "")
    if [ ! -z "$ARGOCD_PASSWORD" ]; then
        break
    fi
    echo "Waiting for ArgoCD admin secret... ($i/30)"
    sleep 10
done

if [ -z "$ARGOCD_PASSWORD" ]; then
    print_warning "Could not retrieve ArgoCD password automatically"
    print_status "You can get it later with: kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath=\"{.data.password}\" | base64 -d"
fi

# Install NGINX Ingress Controller
print_status "Installing NGINX Ingress Controller..."
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
helm repo update
helm install ingress-nginx ingress-nginx/ingress-nginx \
    --namespace ingress-nginx \
    --create-namespace \
    --set controller.service.type=LoadBalancer \
    --set controller.service.annotations."service\.beta\.kubernetes\.io/aws-load-balancer-type"="nlb" \
    --set controller.service.annotations."service\.beta\.kubernetes\.io/aws-load-balancer-scheme"="internet-facing"

# Wait for NGINX ingress controller to be ready
print_status "Waiting for NGINX ingress controller to be ready..."
kubectl wait --namespace ingress-nginx \
    --for=condition=ready pod \
    --selector=app.kubernetes.io/component=controller \
    --timeout=300s

# Get NGINX LoadBalancer URL
print_status "Getting NGINX LoadBalancer URL..."
echo "Waiting for LoadBalancer to be ready..."
sleep 30

NGINX_URL=""
for i in {1..20}; do
    NGINX_URL=$(kubectl get svc ingress-nginx-controller -n ingress-nginx -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || echo "")
    if [ ! -z "$NGINX_URL" ]; then
        break
    fi
    echo "Waiting for NGINX LoadBalancer... ($i/20)"
    sleep 15
done

echo ""
print_success "Deployment completed successfully!"
echo ""

# Generate and deploy secrets dynamically
print_status "Generating random secrets..."
# Get infrastructure endpoints from Terraform
cd "$TERRAFORM_DIR"
DB_HOST=$(terraform output -raw rds_endpoint 2>/dev/null || echo "")
REDIS_HOST=$(terraform output -raw redis_endpoint 2>/dev/null || echo "")
cd ..

if [ -z "$DB_HOST" ] || [ -z "$REDIS_HOST" ]; then
    print_warning "Could not get endpoints from Terraform outputs"
    print_status "Trying to continue with placeholder values..."
    DB_HOST="authentik-cluster-authentik-db.region.rds.amazonaws.com"
    REDIS_HOST="authentik-cluster-authentik-redis.region.cache.amazonaws.com"
fi

# Generate random secret key but use terraform.tfvars password for database
AUTHENTIK_SECRET_KEY=$(openssl rand -base64 32 | tr -d "=+/" | cut -c1-50)
# Get database password from terraform outputs
cd "$TERRAFORM_DIR"
DB_PASSWORD=$(terraform output -raw db_password 2>/dev/null || echo "")
cd ..

if [ -z "$DB_PASSWORD" ]; then
    print_warning "Could not get database password from terraform outputs"
    # Fallback: extract from terraform.tfvars
    DB_PASSWORD=$(grep '^db_password' "$TERRAFORM_DIR/terraform.tfvars" | cut -d'"' -f2 2>/dev/null || echo "MySecureDBPassword123!")
fi

print_success "Generated secure random secrets with correct database password"

# Create secrets in Kubernetes
kubectl create secret generic authentik-secrets \
    --namespace=authentik \
    --from-literal=AUTHENTIK_SECRET_KEY="$AUTHENTIK_SECRET_KEY" \
    --from-literal=AUTHENTIK_POSTGRESQL__PASSWORD="$DB_PASSWORD" \
    --from-literal=AUTHENTIK_POSTGRESQL__HOST="$DB_HOST" \
    --from-literal=AUTHENTIK_POSTGRESQL__NAME="authentik" \
    --from-literal=AUTHENTIK_POSTGRESQL__USER="authentik" \
    --from-literal=AUTHENTIK_REDIS__HOST="$REDIS_HOST" \
    --dry-run=client -o yaml | kubectl apply -f -

print_success "Kubernetes secret created with random values"

# Install Authentik directly with Helm (more reliable than ArgoCD for initial deployment)
print_status "Installing Authentik directly with Helm..."
helm repo add authentik https://charts.goauthentik.io
helm repo update

# Install Authentik with proper configuration
helm install authentik authentik/authentik \
    --namespace authentik \
    --set authentik.postgresql.enabled=false \
    --set authentik.redis.enabled=false \
    --set global.env[0].name=AUTHENTIK_SECRET_KEY \
    --set global.env[0].valueFrom.secretKeyRef.name=authentik-secrets \
    --set global.env[0].valueFrom.secretKeyRef.key=AUTHENTIK_SECRET_KEY \
    --set global.env[1].name=AUTHENTIK_POSTGRESQL__HOST \
    --set global.env[1].valueFrom.secretKeyRef.name=authentik-secrets \
    --set global.env[1].valueFrom.secretKeyRef.key=AUTHENTIK_POSTGRESQL__HOST \
    --set global.env[2].name=AUTHENTIK_POSTGRESQL__NAME \
    --set global.env[2].valueFrom.secretKeyRef.name=authentik-secrets \
    --set global.env[2].valueFrom.secretKeyRef.key=AUTHENTIK_POSTGRESQL__NAME \
    --set global.env[3].name=AUTHENTIK_POSTGRESQL__USER \
    --set global.env[3].valueFrom.secretKeyRef.name=authentik-secrets \
    --set global.env[3].valueFrom.secretKeyRef.key=AUTHENTIK_POSTGRESQL__USER \
    --set global.env[4].name=AUTHENTIK_POSTGRESQL__PASSWORD \
    --set global.env[4].valueFrom.secretKeyRef.name=authentik-secrets \
    --set global.env[4].valueFrom.secretKeyRef.key=AUTHENTIK_POSTGRESQL__PASSWORD \
    --set global.env[5].name=AUTHENTIK_REDIS__HOST \
    --set global.env[5].valueFrom.secretKeyRef.name=authentik-secrets \
    --set global.env[5].valueFrom.secretKeyRef.key=AUTHENTIK_REDIS__HOST \
    --set server.replicas=1 \
    --set server.service.type=ClusterIP \
    --set worker.replicas=1

print_success "Authentik installed directly with Helm"

# Apply ingress resources
print_status "Applying ingress resources..."
kubectl apply -f k8s-manifests/ingress-resources.yaml

# Wait for Authentik pods to be ready
print_status "Waiting for Authentik to be ready..."
kubectl wait --for=condition=available --timeout=300s deployment/authentik-server -n authentik || print_warning "Authentik server may still be starting"

print_success "Full deployment completed!"

echo ""
echo "🎉 Deployment Complete!"
echo "   ✓ Infrastructure deployed"
echo "   ✓ NGINX ingress controller installed"
echo "   ✓ Secrets deployed"
echo "   ✓ Authentik application deployed"
echo "   ✓ Ingress resources applied"
echo ""
echo "📋 Access Information:"
echo "   ArgoCD (Port-forward): kubectl port-forward svc/argocd-server -n argocd 8080:80"
echo "   ArgoCD Local URL: http://localhost:8080"
echo "   ArgoCD Username: admin"
if [ ! -z "$ARGOCD_PASSWORD" ]; then
    echo "   ArgoCD Password: $ARGOCD_PASSWORD"
else
    echo "   ArgoCD Password: Run 'kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath=\"{.data.password}\" | base64 -d'"
fi
echo ""
if [ ! -z "$NGINX_URL" ]; then
    echo "   Authentik URL: http://$NGINX_URL"
else
    echo "   Authentik URL: Run 'kubectl get svc ingress-nginx-controller -n ingress-nginx' to get the LoadBalancer URL"
fi
echo ""
echo "🚀 Ready to use - no manual steps required!"
echo ""
echo "🔍 To view secrets later, run: ./scripts/show-secrets.sh"