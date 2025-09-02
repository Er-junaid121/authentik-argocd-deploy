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

# Get LoadBalancer URLs
print_status "Getting service URLs..."
echo "Waiting for LoadBalancer to be ready..."
sleep 30

ARGOCD_URL=""
for i in {1..20}; do
    ARGOCD_URL=$(kubectl get svc argocd-server -n argocd -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || echo "")
    if [ ! -z "$ARGOCD_URL" ]; then
        break
    fi
    echo "Waiting for ArgoCD LoadBalancer... ($i/20)"
    sleep 15
done

cd ..

echo ""
print_success "Deployment completed successfully!"
echo ""
echo "📋 Access Information:"
if [ ! -z "$ARGOCD_URL" ]; then
    echo "   ArgoCD URL: http://$ARGOCD_URL"
else
    echo "   ArgoCD URL: Run 'kubectl get svc argocd-server -n argocd' to get the LoadBalancer URL"
fi
echo "   ArgoCD Username: admin"
if [ ! -z "$ARGOCD_PASSWORD" ]; then
    echo "   ArgoCD Password: $ARGOCD_PASSWORD"
else
    echo "   ArgoCD Password: Run 'kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath=\"{.data.password}\" | base64 -d'"
fi
echo ""
echo "🔧 Next steps:"
echo "   1. Access ArgoCD web interface"
echo "   2. Deploy Authentik application via ArgoCD"
echo "   3. Configure Authentik once it's running"
echo ""
echo "🚀 To deploy Authentik via ArgoCD:"
echo "   kubectl apply -f argocd/applications/authentik.yaml"