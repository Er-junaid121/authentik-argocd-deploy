#!/bin/bash
set -e

echo "🧹 Starting cleanup of Authentik + ArgoCD deployment..."

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

TERRAFORM_DIR="./terraform"
CLUSTER_NAME=${CLUSTER_NAME:-"authentik-cluster"}
AWS_REGION=${AWS_REGION:-"ap-south-1"}

echo ""
print_warning "This will destroy all AWS resources created for this project!"
echo "   Cluster Name: $CLUSTER_NAME"
echo "   AWS Region: $AWS_REGION"
echo ""

read -p "Are you sure you want to continue? Type 'yes' to confirm: " -r
if [[ ! $REPLY == "yes" ]]; then
    print_status "Cleanup cancelled."
    exit 0
fi

# Configure kubectl if cluster still exists
print_status "Attempting to configure kubectl..."
aws eks update-kubeconfig --region $AWS_REGION --name $CLUSTER_NAME 2>/dev/null || print_warning "Could not configure kubectl (cluster may not exist)"

# Change to project root directory
cd "$(dirname "$0")/.."

# Delete NGINX ingress controller
print_status "Deleting NGINX ingress controller..."
helm uninstall ingress-nginx -n ingress-nginx || print_warning "Could not delete NGINX ingress controller"

# Delete ingress resources
print_status "Deleting ingress resources..."
kubectl delete -f "k8s-manifests/ingress-resources.yaml" --ignore-not-found=true || print_warning "Could not delete ingress resources"

# Delete ArgoCD applications
print_status "Deleting ArgoCD applications..."
kubectl delete -f "argocd/applications/authentik.yaml" --ignore-not-found=true || print_warning "Could not delete Authentik application"

# Wait for applications to be cleaned up
print_status "Waiting for resources to be cleaned up..."
sleep 30

# Delete any remaining LoadBalancer services to avoid orphaned AWS resources
print_status "Cleaning up LoadBalancer services..."
kubectl delete svc --all-namespaces --field-selector spec.type=LoadBalancer --ignore-not-found=true || print_warning "Could not delete LoadBalancer services"

# Wait for LoadBalancers to be cleaned up
sleep 60

# Destroy Terraform infrastructure
print_status "Destroying Terraform infrastructure..."
cd $TERRAFORM_DIR

# First, try to destroy with auto-approve
terraform destroy -auto-approve || {
    print_warning "Terraform destroy failed. This might be due to dependencies."
    print_status "Trying to force destroy problematic resources..."
    
    # Try to manually clean up known problematic resources
    print_status "Attempting to clean up EKS node groups manually..."
    
    # Re-run destroy
    terraform destroy -auto-approve
}

print_success "Cleanup completed!"
echo ""
print_status "If you encounter any issues, manually check and delete:"
echo "   - EKS cluster: $CLUSTER_NAME"
echo "   - VPC and related resources"  
echo "   - RDS instance: ${CLUSTER_NAME}-authentik-db"
echo "   - ElastiCache cluster: ${CLUSTER_NAME}-authentik-redis"